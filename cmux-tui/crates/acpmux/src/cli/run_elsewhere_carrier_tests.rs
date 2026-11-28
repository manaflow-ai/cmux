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

/// A far machine that runs each call here: `exec` for real unless its program is in `refuse`
/// (as a revoked grant answers), `fs.write` through the hand's own write. It records the folder's
/// and payload's modes as written.
struct Far {
    refuse: &'static [&'static str],
    seen: Arc<Mutex<Vec<(String, u32, u32)>>>,
}

impl Far {
    fn new(refuse: &'static [&'static str]) -> Self {
        Far { refuse, seen: Arc::new(Mutex::new(Vec::new())) }
    }

    fn caller(&self) -> impl FnMut(Value) -> BoxFuture<'static, Result<Value>> + use<> {
        let (refuse, seen) = (self.refuse, self.seen.clone());
        move |params: Value| {
            let seen = seen.clone();
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
                        seen.lock().unwrap().push((
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
                        if refuse.contains(&argv[0]) {
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

fn deliver_now(far: &Far, run: &str, script: &str) -> Result<Value> {
    let mut call = far.caller();
    let path = PathBuf::from(format!("/h/run-elsewhere/{run}.sh"));
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(deliver(&mut call, "cloud-a", &path, script))
}

fn a_run() -> String {
    format!("t{}", uuid::Uuid::now_v7().simple())
}

fn left_behind(run: &str) -> Vec<PathBuf> {
    std::fs::read_dir("/tmp")
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.to_string_lossy().starts_with(&format!("{FAR_PREFIX}{run}-")))
        .collect()
}

/// Puts the process umask back however the test ends.
struct Umask(libc::mode_t);

impl Umask {
    fn set(mask: libc::mode_t) -> Self {
        // SAFETY: umask only swaps this process's file creation mask.
        Umask(unsafe { libc::umask(mask) })
    }
}

impl Drop for Umask {
    fn drop(&mut self) {
        // SAFETY: as above, restoring the mask this guard replaced.
        unsafe { libc::umask(self.0) };
    }
}

const UMASK_CHILD: &str = "ACPMUX_TEST_RUN_ELSEWHERE_UMASK_CHILD";

/// The umask is process-wide, so the part under umask 022 runs in a child copy of this test
/// binary that runs only it: no other test shares that process.
#[test]
fn under_umask_022_the_payload_is_never_readable_by_others_and_the_run_removes_it() {
    if std::env::var_os(UMASK_CHILD).is_none() {
        let name = "cli::run_elsewhere_carrier::tests::\
                    under_umask_022_the_payload_is_never_readable_by_others_and_the_run_removes_it";
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([name, "--exact", "--test-threads=1", "--nocapture"])
            .env(UMASK_CHILD, "1")
            .output()
            .unwrap();
        let said = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success(), "{said}{}", String::from_utf8_lossy(&out.stderr));
        assert!(said.contains("1 passed"), "the child ran nothing: {said}");
        return;
    }
    let _umask = Umask::set(0o022);
    let run = a_run();
    let far = Far::new(&[]);
    let reply = deliver_now(&far, &run, "echo from-far\nexit 3\n").unwrap();
    assert_eq!(reply["stdout"], "from-far\n");
    assert_eq!(outcome(&reply).0, 3);
    let seen = far.seen.lock().unwrap();
    let (dir, dir_mode, _file_mode) = &seen[0];
    assert!(dir.starts_with(FAR_PREFIX), "{dir}");
    // The folder is the guard: nobody else may even pass through it to the 0644 file.
    assert_eq!(dir_mode & 0o077, 0, "folder mode {dir_mode:o}");
    assert!(left_behind(&run).is_empty(), "{:?}", left_behind(&run));
}

#[test]
fn a_refused_exec_leaves_no_payload_behind() {
    let run = a_run();
    let far = Far::new(&["/bin/bash"]);
    let err = deliver_now(&far, &run, "echo never\n").unwrap_err();
    let said = format!("{err:#}");
    assert!(said.contains("not granted"), "{said}");
    assert!(!said.contains("still there"), "{said}");
    assert_eq!(far.seen.lock().unwrap().len(), 1, "the script was written before the refusal");
    assert!(left_behind(&run).is_empty(), "{:?}", left_behind(&run));
}

#[test]
fn a_revoked_grant_that_refuses_the_cleanup_names_the_private_folder_left() {
    let run = a_run();
    let far = Far::new(&["/bin/bash", "rm"]);
    let err = deliver_now(&far, &run, "echo never\n").unwrap_err();
    let said = format!("{err:#}");
    let left = left_behind(&run);
    // This test made the folder (through the fake far side); it removes it.
    for dir in &left {
        std::fs::remove_dir_all(dir).unwrap();
    }
    assert_eq!(left.len(), 1, "{left:?}");
    let folder = left[0].display().to_string();
    assert!(said.contains("not granted"), "{said}");
    assert!(said.contains(&format!("{folder} is still there")), "{said}");
    assert!(said.contains("remove it by hand"), "{said}");
}
