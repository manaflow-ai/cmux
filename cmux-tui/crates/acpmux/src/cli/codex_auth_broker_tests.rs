use super::*;
use std::os::unix::fs::PermissionsExt;

struct Home(PathBuf);
impl Home {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("cmux-codex-broker-{}", uuid::Uuid::now_v7()));
        crate::config::private_state_dir(&path).unwrap();
        Self(path)
    }
    fn auth(&self, expiry: u64) {
        let jwt = format!(
            "e30.{}.sig",
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(json!({"exp": expiry}).to_string())
        );
        let cache = json!({"auth_mode": "chatgpt", "tokens": {
            "access_token": jwt, "account_id": "account-one",
            "refresh_token": "must-stay-local", "id_token": "also-local"
        }});
        std::fs::write(self.0.join("auth.json"), cache.to_string()).unwrap();
        std::fs::set_permissions(self.0.join("auth.json"), std::fs::Permissions::from_mode(0o600))
            .unwrap();
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).ok();
    }
}

#[tokio::test]
async fn private_input_is_cancellable_without_closing_the_writer() {
    use std::io::Write;
    let (reader, mut writer) = std::os::unix::net::UnixStream::pair().unwrap();
    let input = nonblocking_input(reader.into()).unwrap();
    let mut buffer = Vec::new();
    assert!(
        tokio::time::timeout(Duration::from_millis(10), request_line(&input, &mut buffer))
            .await
            .is_err()
    );
    writer.write_all(b"{\"id\":1}\n{\"id\":2}\n").unwrap();
    assert_eq!(request_line(&input, &mut buffer).await.unwrap().as_deref(), Some("{\"id\":1}\n"));
    assert_eq!(request_line(&input, &mut buffer).await.unwrap().as_deref(), Some("{\"id\":2}\n"));
    writer.write_all(&vec![b'x'; 4097]).unwrap();
    assert!(request_line(&input, &mut buffer).await.is_err());
}

#[tokio::test]
async fn private_output_is_cancellable_when_the_reader_stalls() {
    let (_reader, writer) = std::os::unix::net::UnixStream::pair().unwrap();
    let size: libc::c_int = 2048;
    // SAFETY: writer owns this live socket and size is a c_int of the stated size.
    let changed = unsafe {
        libc::setsockopt(
            writer.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_SNDBUF,
            (&size as *const libc::c_int).cast(),
            std::mem::size_of_val(&size) as _,
        )
    };
    assert_eq!(changed, 0);
    let output = nonblocking_input(writer.into()).unwrap();
    let reply = json!({"accessToken": "x".repeat(32 * 1024)});
    assert!(
        tokio::time::timeout(Duration::from_millis(10), write_reply(&output, &reply))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn closed_reply_pipe_returns_error_instead_of_sigpipe() {
    const CHILD: &str = "CMUX_BROKER_TEST_SIGPIPE";
    if std::env::var_os(CHILD).is_none() {
        let result = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "cli::codex_auth_broker::tests::closed_reply_pipe_returns_error_instead_of_sigpipe",
                "--nocapture",
            ])
            .env(CHILD, "1")
            .output()
            .await
            .unwrap();
        assert!(result.status.success(), "isolated signal test failed: {:?}", result.status);
        return;
    }
    // Exercise the actual CLI default in an isolated process, never change
    // another parallel test's signal disposition.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    ignore_broken_pipe().unwrap();
    let (reader, writer) = std::os::unix::net::UnixStream::pair().unwrap();
    let output = nonblocking_input(writer.into()).unwrap();
    drop(reader);
    assert!(write_reply(&output, &json!({"id": 1})).await.is_err());
}

#[test]
fn broker_refuses_two_holders_and_preserves_refreshed_state() {
    let home = Home::new();
    let holder = prepare(&home.0).unwrap();
    assert!(prepare(&home.0).is_err());
    home.auth(u64::MAX);
    let before = std::fs::read(home.0.join("auth.json")).unwrap();
    // Other parallel tests can fork between close and exec. Explicit release
    // keeps this persistence test independent of their transient inherited fd.
    holder.unlock().unwrap();
    drop(holder);
    let _next = prepare(&home.0).unwrap();
    assert_eq!(before, std::fs::read(home.0.join("auth.json")).unwrap());
}

#[test]
fn broker_never_adopts_a_shared_cli_seed() {
    let home = Home::new();
    home.auth(u64::MAX);
    assert!(prepare(&home.0).is_err());
    assert!(!home.0.join("broker-owned").exists());
}

#[test]
fn access_reply_excludes_refresh_and_id_tokens() {
    let home = Home::new();
    home.auth(u64::MAX);
    let reply = access(&home.0.join("auth.json")).unwrap();
    assert_eq!(reply["chatgptAccountId"], "account-one");
    assert_eq!(reply.as_object().unwrap().len(), 3);
    assert!(!reply.to_string().contains("must-stay-local"));
    assert!(!reply.to_string().contains("also-local"));
}

#[test]
fn access_refuses_expired_shared_or_linked_credentials() {
    let home = Home::new();
    let path = home.0.join("auth.json");
    home.auth(1);
    assert!(access(&path).is_err());
    home.auth(u64::MAX);
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(access(&path).is_err());
    let other = home.0.join("other.json");
    std::fs::rename(&path, &other).unwrap();
    std::os::unix::fs::symlink(&other, &path).unwrap();
    assert!(access(&path).is_err());
}

#[tokio::test]
async fn broker_uses_codex_refresh_and_pins_account_without_leaking_errors() {
    let home = Home::new();
    let holder = prepare(&home.0).unwrap();
    home.auth(u64::MAX);
    let codex = home.0.join("fake-codex");
    crate::test_exec::write_executable(
        &codex,
        r#"#!/usr/bin/env python3
import os, sys, json, base64, time
for line in sys.stdin:
    r = json.loads(line)
    if 'id' not in r: continue
    method = r['method']
    result = {}
    path = os.path.join(os.environ['CODEX_HOME'], 'auth.json')
    if method == 'account/logout' and os.path.exists(path): os.unlink(path)
    if method == 'account/login/start':
        assert not os.path.exists(path)
        result = {'verificationUrl':'https://auth.openai.com/codex/device','userCode':'TEST-1234'}
    if method == 'account/read':
        assert r['params']['refreshToken'] is True
        payload = base64.urlsafe_b64encode(json.dumps({'exp':int(time.time())+3600}).encode()).decode().rstrip('=')
        path = os.path.join(os.environ['CODEX_HOME'], 'auth.json')
        with open(path, 'w', opener=lambda p,f: os.open(p,f,0o600)) as f:
            json.dump({'auth_mode':'chatgpt','tokens':{'access_token':'e30.'+payload+'.sig','account_id':'account-one','refresh_token':'rotated-private'}}, f)
    print(json.dumps({'id':r['id'],'result':result}), flush=True)
"#,
    );
    let mut terminate =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
    let mut owner = Owner::start(&home.0, &codex, &holder, &mut terminate).await.unwrap().unwrap();
    // An abrupt parent exit closes its lock descriptor before the child exits.
    // The child must keep the lock, or a replacement could rotate concurrently.
    drop(holder);
    assert!(prepare(&home.0).is_err());
    let prompt = owner.request(&home.0, &json!({"method": "login"})).await.unwrap();
    assert_eq!(prompt["userCode"], "TEST-1234");
    assert!(!home.0.join("auth.json").exists(), "a pending new login cannot reuse an old grant");
    let request = json!({"method": "access", "force": true});
    let reply = owner.request(&home.0, &request).await.unwrap();
    assert!(!reply.to_string().contains("rotated-private"));
    assert!(std::fs::read_to_string(home.0.join("auth.json")).unwrap().contains("rotated-private"));
    let mismatch =
        json!({"method": "access", "force": true, "previousAccountId": "different-account"});
    let mismatch_error = owner.request(&home.0, &mismatch).await.unwrap_err();
    assert_eq!(error_code(&mismatch_error), "codex_auth_account_changed");
    let login_error = owner.request(&home.0, &json!({"method": "login"})).await.unwrap_err();
    assert_eq!(error_code(&login_error), "codex_auth_account_changed");
    owner.stop().await;
    assert!(prepare(&home.0).is_ok());
}

#[tokio::test]
async fn owner_stop_unlocks_when_a_detached_child_keeps_the_lock_fd() {
    inherited_lock_after_shutdown(true).await;
}

#[tokio::test]
async fn owner_drop_preserves_the_lock_until_inherited_descriptors_close() {
    inherited_lock_after_shutdown(false).await;
}

async fn inherited_lock_after_shutdown(stop: bool) {
    let home = Home::new();
    let holder = prepare(&home.0).unwrap();
    let codex = home.0.join("fake-codex");
    crate::test_exec::write_executable(
        &codex,
        r#"#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if request.get('id') is not None:
        print(json.dumps({'id': request['id'], 'result': {}}), flush=True)
"#,
    );
    let mut terminate =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
    let mut owner = Owner::start(&home.0, &codex, &holder, &mut terminate).await.unwrap().unwrap();

    // Model an unrelated fork retaining only this lock's open-file description.
    // Passing fd 3 explicitly works on every Unix platform without /proc or
    // /dev/fd symlink assumptions, and keeps other tests' descriptors private.
    let fd = holder.as_raw_fd();
    let mut command = Command::new("sleep");
    command.arg("30").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    command.kill_on_drop(true);
    // SAFETY: the child calls only async-signal-safe dup2/fcntl before exec.
    unsafe {
        command.pre_exec(move || {
            let ok = if fd == 3 {
                libc::fcntl(fd, libc::F_SETFD, 0) == 0
            } else {
                libc::dup2(fd, 3) == 3
            };
            if ok { Ok(()) } else { Err(std::io::Error::last_os_error()) }
        });
    }
    let mut child = command.spawn().unwrap();
    drop(holder);
    assert!(prepare(&home.0).is_err());
    if stop {
        owner.stop().await;
    }
    drop(owner);
    let child_is_alive = child.try_wait().unwrap().is_none();
    let next = prepare(&home.0);
    child.kill().await.unwrap();
    child.wait().await.unwrap();
    assert!(child_is_alive, "the descriptor holder must outlive shutdown");
    assert_eq!(next.is_ok(), stop, "only confirmed stop may explicitly unlock");
}

#[tokio::test]
async fn stalled_owner_cancellation_releases_inherited_lock() {
    let home = Home::new();
    let holder = prepare(&home.0).unwrap();
    let codex = home.0.join("stalled-codex");
    crate::test_exec::write_executable(
        &codex,
        r#"#!/bin/sh
sleep 30
"#,
    );
    let (sender, mut receiver) = tokio::sync::oneshot::channel();
    let mut start = Box::pin(Owner::start_with_cancel(
        &home.0,
        &codex,
        &holder,
        StartupCancellation::Channel(&mut receiver),
    ));
    tokio::select! {
        _ = &mut start => panic!("stalled startup unexpectedly returned"),
        _ = tokio::time::sleep(Duration::from_millis(100)) => sender.send(()).unwrap(),
    }
    assert!(start.await.unwrap().is_none(), "shutdown must cancel startup after reaping Codex");
    drop(holder);
    for _ in 0..20 {
        if prepare(&home.0).is_ok() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("a cancelled startup must not strand broker.lock");
}
