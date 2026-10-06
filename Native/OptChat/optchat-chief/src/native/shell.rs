//! The `bash` tool (Anthropic's `bash_20250124`): runs one command and
//! returns its combined output. Each command is its own `bash -c` in its
//! own process group, so a timeout kills everything it started.
//!
//! Deviation from the tool's persistent session: the working directory
//! carries over between commands (it is read back after each one), but
//! shell variables, functions and `export`s do not. A fresh process per
//! command is what makes the timeout and the kill reliable.

use std::collections::BTreeMap;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::sync::mpsc::{RecvTimeoutError, channel};
use std::time::Duration;

/// Output kept in memory per command; the rest is counted, not kept (the
/// result is capped at CAP characters anyway, head and tail).
const KEEP: usize = 4 << 20;
/// How long the output may stay open after bash exited (a background
/// process holding it), and after a kill.
const GRACE: Duration = Duration::from_secs(2);

enum Event {
    Chunk(Vec<u8>),
    Eof,
    Exit(Option<i32>),
}

pub struct Shell {
    home: PathBuf,
    cwd: Mutex<PathBuf>,
    env: BTreeMap<String, String>,
    /// Where each command writes its final directory.
    pwd_file: PathBuf,
}

impl Shell {
    /// A shell that starts in `home`, with `env` over the host's environment.
    pub fn new(home: &Path, env: BTreeMap<String, String>, pwd_file: PathBuf) -> Shell {
        Shell {
            home: home.to_owned(),
            cwd: Mutex::new(home.to_owned()),
            env,
            pwd_file,
        }
    }

    pub fn cwd(&self) -> PathBuf {
        self.cwd.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// Back to the start directory (`{"restart": true}`).
    pub fn restart(&self) {
        *self.cwd.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = self.home.clone();
    }

    /// Runs `command`; Err is a failure to run it at all. A non-zero exit is
    /// a normal result that names the code.
    pub fn run(&self, command: &str, timeout: Duration) -> Result<String, String> {
        let cwd = self.cwd();
        let cwd = if cwd.is_dir() { cwd } else { self.home.clone() };
        let pwd = self.pwd_file.display().to_string();
        let script = format!(
            "exec 2>&1\n{command}\n__optchat_rc=$?\npwd > {} 2>/dev/null\nexit $__optchat_rc\n",
            crate::session_dir::shell_quote(&pwd)
        );
        let _ = std::fs::remove_file(&self.pwd_file);
        let mut child = Command::new("/bin/bash")
            .arg("-c")
            .arg(script)
            .current_dir(&cwd)
            .envs(&self.env)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .map_err(|e| format!("starting bash: {e}"))?;
        let mut stdout = child.stdout.take().ok_or_else(|| "bash has no stdout pipe".to_owned())?;
        let pid = child.id() as i32;
        let (tx, rx) = channel();
        let output = tx.clone();
        // Output streams to this thread as it comes, so what a command printed
        // is kept even when a background process holds the pipe open.
        std::thread::Builder::new()
            .name("bash-output".into())
            .spawn(move || {
                let mut buf = [0u8; 64 * 1024];
                loop {
                    match stdout.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if output.send(Event::Chunk(buf[..n].to_vec())).is_err() {
                                break;
                            }
                        }
                    }
                }
                let _ = output.send(Event::Eof);
            })
            .map_err(|e| e.to_string())?;
        std::thread::Builder::new()
            .name("bash-wait".into())
            .spawn(move || {
                let _ = tx.send(Event::Exit(child.wait().ok().and_then(|s| s.code())));
            })
            .map_err(|e| e.to_string())?;
        let deadline = std::time::Instant::now() + timeout;
        let mut kept: Vec<u8> = Vec::new();
        let mut dropped = 0usize;
        let mut eof = false;
        let mut exit = None;
        let mut timed_out = false;
        let mut held_open = false;
        while !eof || exit.is_none() {
            // Once bash itself exited, its output closes at once unless a
            // process it left in the background holds it: then the result
            // goes back without waiting for that process (it keeps running).
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            let wait = if timed_out {
                GRACE
            } else if exit.is_some() {
                GRACE.min(left)
            } else {
                left
            };
            match rx.recv_timeout(wait) {
                Ok(Event::Chunk(bytes)) => {
                    let room = KEEP.saturating_sub(kept.len()).min(bytes.len());
                    kept.extend_from_slice(&bytes[..room]);
                    dropped += bytes.len() - room;
                }
                Ok(Event::Eof) => eof = true,
                Ok(Event::Exit(code)) => exit = Some(code),
                Err(RecvTimeoutError::Timeout) if timed_out => break,
                Err(RecvTimeoutError::Timeout) if exit.is_some() => {
                    held_open = true;
                    break;
                }
                Err(RecvTimeoutError::Timeout) => {
                    timed_out = true;
                    // SAFETY: kill(2) on the command's own process group.
                    unsafe { libc::kill(-pid, libc::SIGKILL) };
                }
                Err(RecvTimeoutError::Disconnected) => break,
            }
        }
        let status = exit.flatten();
        if let Ok(dir) = std::fs::read_to_string(&self.pwd_file) {
            let dir = PathBuf::from(dir.trim_end_matches('\n'));
            if dir.is_dir() {
                *self.cwd.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = dir;
            }
        }
        let mut text = String::from_utf8_lossy(&kept).into_owned();
        if dropped > 0 {
            text.push_str(&format!("\n[{dropped} more bytes of output not kept]"));
        }
        if held_open {
            text.push_str("\n(a background process still holds the output; what it prints later is not shown)");
        }
        if timed_out {
            text.push_str(&format!(
                "\n(stopped: the command ran past {} s and was killed)",
                timeout.as_secs()
            ));
        } else if let Some(code) = status.filter(|c| *c != 0) {
            text.push_str(&format!("\n(exit code {code})"));
        }
        Ok(text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell(dir: &Path) -> Shell {
        Shell::new(dir, BTreeMap::new(), dir.join(".pwd"))
    }

    #[test]
    fn output_exit_code_and_the_directory_carry_over() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir(root.join("sub")).unwrap();
        let sh = shell(&root);
        assert_eq!(
            sh.run("echo hi; echo err >&2", Duration::from_secs(10))
                .unwrap(),
            "hi\nerr\n"
        );
        assert!(
            sh.run("false", Duration::from_secs(10))
                .unwrap()
                .ends_with("(exit code 1)")
        );
        sh.run("cd sub", Duration::from_secs(10)).unwrap();
        assert_eq!(sh.cwd(), root.join("sub"));
        assert_eq!(
            sh.run("pwd", Duration::from_secs(10)).unwrap(),
            format!("{}\n", root.join("sub").display())
        );
        sh.restart();
        assert_eq!(sh.cwd(), root);
    }

    #[test]
    fn a_background_process_holding_the_output_does_not_hold_the_result() {
        let dir = tempfile::tempdir().unwrap();
        let sh = shell(dir.path());
        let started = std::time::Instant::now();
        let out = sh
            .run("echo up; sleep 20 &", Duration::from_secs(30))
            .unwrap();
        assert!(started.elapsed() < Duration::from_secs(10), "{out}");
        assert!(
            out.starts_with("up\n") && out.contains("background process"),
            "{out}"
        );
    }

    #[test]
    fn a_command_past_its_timeout_is_killed_with_its_children() {
        let dir = tempfile::tempdir().unwrap();
        let sh = shell(dir.path());
        let started = std::time::Instant::now();
        let out = sh
            .run(
                "echo start; sleep 30 & sleep 30",
                Duration::from_millis(300),
            )
            .unwrap();
        assert!(started.elapsed() < Duration::from_secs(10));
        assert!(
            out.starts_with("start\n") && out.contains("was killed"),
            "{out}"
        );
    }
}
