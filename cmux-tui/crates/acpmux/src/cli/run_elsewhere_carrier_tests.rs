use super::*;
use std::os::unix::fs::PermissionsExt;
use std::sync::{Arc, Mutex};

#[test]
fn the_private_folder_is_named_for_its_run() {
    let t = far_template(Path::new("/home/me/.acpmux/run-elsewhere/0192abcd.sh")).unwrap();
    assert_eq!(t, "/tmp/cmux-run-elsewhere-0192abcd-XXXXXX");
    assert!(far_template(Path::new("/x/../evil name.sh")).is_err());
    assert!(far_template(Path::new("/x/a;b.sh")).is_err());
    let ok = json!({"exit": 0, "stdout": "/tmp/cmux-run-elsewhere-r1-Ab12Cd\n"});
    let t = "/tmp/cmux-run-elsewhere-r1-XXXXXX";
    assert_eq!(made_folder(&ok, t).unwrap(), "/tmp/cmux-run-elsewhere-r1-Ab12Cd");
    for bad in [
        json!({"exit": 1, "stdout": "/tmp/cmux-run-elsewhere-r1-Ab12Cd"}),
        json!({"exit": 0, "stdout": "/home/x"}),
        json!({"exit": 0, "stdout": "/tmp/cmux-run-elsewhere-r1-../../x"}),
    ] {
        assert!(made_folder(&bad, t).is_err(), "{bad}");
    }
}

#[test]
fn the_patch_is_written_into_the_folder_then_run_and_removes_it_first() {
    let folder = "/tmp/cmux-run-elsewhere-r1-Ab12Cd";
    let [write, exec] = run_calls("cloud-a", folder, "set -eu\necho hi\n");
    assert_eq!(write["machine"], "cloud-a");
    assert_eq!(write["action"], "fs.write");
    assert_eq!(write["params"]["path"], format!("{folder}/run.sh"));
    let text = write["params"]["text"].as_str().unwrap();
    assert!(text.starts_with("rm -rf -- \"${0%/*}\"\nset -eu\n"), "{text}");
    assert_eq!(exec["params"]["argv"], json!(["/bin/bash", format!("{folder}/run.sh")]));
    assert_eq!(exec["params"]["timeout_ms"], 600_000);
    let mkdir = mkdir_call("cloud-a", "/tmp/cmux-run-elsewhere-r1-XXXXXX");
    let clean = cleanup_call("cloud-a", folder);
    // Every call passes the relay's own checks.
    for call in [&mkdir, &write, &exec, &clean] {
        crate::machine_files::parse(call).unwrap();
    }
}

#[test]
fn the_exit_code_and_end_come_from_the_far_answer() {
    assert_eq!(outcome(&json!({"exit": 3})), (3, None));
    let (code, note) = outcome(&json!({"exit": 0, "truncated": true}));
    assert_eq!(code, 0);
    assert!(note.unwrap().contains("256 KB"));
    assert_eq!(outcome(&json!({"timed_out": true})).0, 124);
    assert_eq!(outcome(&json!({})).0, 137);
}

/// A far machine that runs each call here: `exec` for real (unless `refuse_bash`), `fs.write`
/// through the hand's own write. It records the folder's and payload's modes as written.
struct Far {
    refuse_bash: bool,
    seen: Arc<Mutex<Vec<(String, u32, u32)>>>,
}

impl Far {
    fn caller(self) -> impl FnMut(Value) -> BoxFuture<'static, Result<Value>> {
        let far = Arc::new(self);
        move |params: Value| {
            let far = far.clone();
            Box::pin(async move {
                crate::machine_files::parse(&params).map_err(|e| anyhow!(e.message))?;
                let p = &params["params"];
                match params["action"].as_str().unwrap() {
                    "fs.write" => {
                        let path = Path::new(p["path"].as_str().unwrap());
                        crate::hand::fsops::write(path, p["text"].as_str().unwrap(), None)
                            .map_err(|e| anyhow!("{e:?}"))?;
                        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode();
                        let dir = path.parent().unwrap();
                        far.seen.lock().unwrap().push((
                            dir.display().to_string(),
                            mode(dir) & 0o777,
                            mode(path) & 0o777,
                        ));
                        Ok(json!({"ok": true}))
                    }
                    "exec" => {
                        let argv: Vec<&str> = p["argv"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .filter_map(Value::as_str)
                            .collect();
                        if far.refuse_bash && argv[0] == "/bin/bash" {
                            bail!("machine_call_denied: exec is not granted");
                        }
                        let out = std::process::Command::new(argv[0]).args(&argv[1..]).output()?;
                        Ok(json!({
                            "exit": out.status.code(),
                            "stdout": String::from_utf8_lossy(&out.stdout),
                            "stderr": String::from_utf8_lossy(&out.stderr),
                        }))
                    }
                    other => bail!("unexpected {other}"),
                }
            })
        }
    }
}

fn under_umask_022<T>(f: impl FnOnce() -> T) -> T {
    // SAFETY: umask only swaps this process's file creation mask.
    let old = unsafe { libc::umask(0o022) };
    let out = f();
    unsafe { libc::umask(old) };
    out
}

fn deliver_now(far: Far, run: &str, script: &str) -> Result<Value> {
    let mut call = far.caller();
    let path = PathBuf::from(format!("/h/run-elsewhere/{run}.sh"));
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    under_umask_022(|| rt.block_on(deliver(&mut call, "cloud-a", &path, script)))
}

fn left_behind(run: &str) -> Vec<PathBuf> {
    std::fs::read_dir("/tmp")
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.to_string_lossy().starts_with(&format!("{FAR_PREFIX}{run}-")))
        .collect()
}

#[test]
fn under_umask_022_the_payload_is_never_readable_by_others_and_the_run_removes_it() {
    let run = format!("t{}", uuid::Uuid::now_v7().simple());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let far = Far { refuse_bash: false, seen: seen.clone() };
    let reply = deliver_now(far, &run, "echo from-far\nexit 3\n").unwrap();
    assert_eq!(reply["stdout"], "from-far\n");
    assert_eq!(outcome(&reply).0, 3);
    let seen = seen.lock().unwrap();
    let (dir, dir_mode, _file_mode) = &seen[0];
    assert!(dir.starts_with(FAR_PREFIX), "{dir}");
    // The folder is the guard: nobody else may even pass through it to the 0644 file.
    assert_eq!(dir_mode & 0o077, 0, "folder mode {dir_mode:o}");
    assert!(left_behind(&run).is_empty(), "{:?}", left_behind(&run));
}

#[test]
fn a_refused_exec_leaves_no_payload_behind() {
    let run = format!("t{}", uuid::Uuid::now_v7().simple());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let far = Far { refuse_bash: true, seen: seen.clone() };
    let err = deliver_now(far, &run, "echo never\n").unwrap_err();
    assert!(format!("{err:#}").contains("not granted"), "{err:#}");
    assert_eq!(seen.lock().unwrap().len(), 1, "the script was written before the refusal");
    assert!(left_behind(&run).is_empty(), "{:?}", left_behind(&run));
}
