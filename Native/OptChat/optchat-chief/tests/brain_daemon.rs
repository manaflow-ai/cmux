//! The Chief host runs Hermes' gateway daemon itself (`hermes gateway run --quiet`): in the
//! Chief's Hermes home, with only the env it needs, in its own process group that ends with the
//! host, and a gateway an earlier host left is ended first. Without it, Hermes' `acp` viewer
//! started the daemon as a launchd job outside the Chief, and where that job never ran every
//! session/new failed with storage_unavailable (cmux-ci steps be2ad7da45a6, eb3f6122e288).

use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt as _;
use std::path::Path;
use std::time::{Duration, Instant};

use optchat_chief::brain_gateway;

/// A fake `hermes`: `gateway run` writes its env and argv, starts a grandchild that holds
/// `gateway.lock` (flock, as Hermes' gateway does), and waits for it
/// (its command line stays `... hermes gateway run --quiet`, as the real one's does).
fn fake_hermes(dir: &Path) -> std::path::PathBuf {
    let path = dir.join("hermes");
    std::fs::write(
        &path,
        "#!/bin/sh\nenv > \"$HERMES_HOME/seen-env\"\necho \"$@\" > \"$HERMES_HOME/seen-args\"\n\
         python3 -c 'import fcntl,os,time; f=open(os.environ[\"HERMES_HOME\"]+\"/gateway.lock\",\"a\"); \
         fcntl.flock(f, fcntl.LOCK_EX); time.sleep(600)' &\n\
         echo $! > \"$HERMES_HOME/grandchild\"\nwait\n",
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn alive(pid: i32) -> bool {
    // SAFETY: kill(2) with signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn wait_for(cond: impl Fn() -> bool) -> bool {
    let end = Instant::now() + Duration::from_secs(10);
    while Instant::now() < end {
        if cond() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

#[test]
fn the_hermes_gateway_runs_in_the_chiefs_home_and_ends_with_the_host() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("brains").join("hermes");
    std::fs::create_dir_all(&home).unwrap();
    let hermes = fake_hermes(dir.path());
    // SAFETY: this test binary's only test.
    unsafe { std::env::set_var("ANTHROPIC_API_KEY", "sk-person-key") };

    let gateway = brain_gateway::start_hermes(&hermes, &home, &|_| {}).unwrap();
    let pid = gateway.pid() as i32;
    assert!(wait_for(|| home.join("grandchild").exists()), "the gateway did not start");
    let args = std::fs::read_to_string(home.join("seen-args")).unwrap();
    assert_eq!(args.trim(), "gateway run --quiet");
    let env = std::fs::read_to_string(home.join("seen-env")).unwrap();
    assert!(env.contains(&format!("HERMES_HOME={}", home.display())), "{env}");
    // Its own gateway rendezvous: the user's own Hermes gateway never serves the Chief.
    assert!(env.contains(&format!("HERMES_GATEWAY_LOCK_DIR={}", home.join("gateway-locks").display())), "{env}");
    assert!(!env.contains("sk-person-key"), "a provider key reached the gateway: {env}");
    assert_eq!(std::fs::read_to_string(home.join("chief-gateway.pid")).unwrap().trim(), pid.to_string());
    let grandchild: i32 = std::fs::read_to_string(home.join("grandchild")).unwrap().trim().parse().unwrap();

    // A host that starts again ends the gateway the earlier one left, then runs its own.
    std::mem::forget(gateway);
    let _ = std::fs::remove_file(home.join("grandchild"));
    let again = brain_gateway::start_hermes(&hermes, &home, &|_| {}).unwrap();
    assert!(wait_for(|| !alive(grandchild)), "the earlier gateway's group was not ended");
    assert!(wait_for(|| home.join("grandchild").exists()));
    let new_grandchild: i32 = std::fs::read_to_string(home.join("grandchild")).unwrap().trim().parse().unwrap();

    // The host lets go: the whole process group ends and the pid file goes.
    drop(again);
    assert!(wait_for(|| !alive(new_grandchild)), "the gateway's group outlived the host");
    assert!(!home.join("chief-gateway.pid").exists());
}

/// A fake `hermes` that exits at once, or runs without ever holding the lock.
fn fake_broken(dir: &Path, body: &str) -> std::path::PathBuf {
    let path = dir.join("hermes");
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[test]
fn a_hermes_gateway_that_never_gets_ready_is_an_error_and_leaves_nothing_running() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let exits = fake_broken(dir.path(), "exit 3");
    let e = brain_gateway::start_hermes_within(&exits, &home, Duration::from_secs(10), &|_| {})
        .err()
        .expect("a gateway that exits is not ready");
    assert!(e.to_string().contains("exited before it was ready"), "{e}");

    let dir2 = tempfile::tempdir().unwrap();
    let home2 = dir2.path().join("home");
    std::fs::create_dir_all(&home2).unwrap();
    let idle = fake_broken(dir2.path(), "echo $$ > \"$HERMES_HOME/me\"\nexec sleep 600");
    let e = brain_gateway::start_hermes_within(&idle, &home2, Duration::from_secs(1), &|_| {})
        .err()
        .expect("a gateway that never holds its lock is not ready");
    assert!(e.to_string().contains("did not hold its gateway.lock"), "{e}");
    let me: i32 = std::fs::read_to_string(home2.join("me")).unwrap().trim().parse().unwrap();
    assert!(wait_for(|| !alive(me)), "the gateway that was not ready is still running");
}

#[test]
fn a_pid_file_naming_another_program_is_never_signalled() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    // A process of another program in its own group, named by a stale pid file.
    let mut other = std::process::Command::new("sleep")
        .arg("600")
        .process_group(0)
        .spawn()
        .unwrap();
    std::fs::write(home.join("chief-gateway.pid"), other.id().to_string()).unwrap();
    let hermes = fake_hermes(dir.path());
    let gateway = brain_gateway::start_hermes(&hermes, &home, &|_| {}).unwrap();
    assert!(alive(other.id() as i32), "a pid of another program was signalled");
    drop(gateway);
    let _ = other.kill();
    let _ = other.wait();
}
