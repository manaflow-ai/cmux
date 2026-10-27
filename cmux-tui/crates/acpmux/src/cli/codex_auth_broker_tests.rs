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

#[test]
fn broker_refuses_two_holders_and_preserves_refreshed_state() {
    let home = Home::new();
    let holder = prepare(&home.0).unwrap();
    assert!(prepare(&home.0).is_err());
    home.auth(u64::MAX);
    let before = std::fs::read(home.0.join("auth.json")).unwrap();
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
    let codex = home.0.join("fake-codex");
    std::fs::write(&codex, r#"#!/usr/bin/env python3
import os, sys, json, base64, time
for line in sys.stdin:
    r = json.loads(line)
    if 'id' not in r: continue
    method = r['method']
    if method == 'account/read':
        assert r['params']['refreshToken'] is True
        payload = base64.urlsafe_b64encode(json.dumps({'exp':int(time.time())+3600}).encode()).decode().rstrip('=')
        path = os.path.join(os.environ['CODEX_HOME'], 'auth.json')
        with open(path, 'w', opener=lambda p,f: os.open(p,f,0o600)) as f:
            json.dump({'auth_mode':'chatgpt','tokens':{'access_token':'e30.'+payload+'.sig','account_id':'account-one','refresh_token':'rotated-private'}}, f)
    print(json.dumps({'id':r['id'],'result':{}}), flush=True)
"#).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut owner = Owner::start(&home.0, &codex, &holder).await.unwrap();
    // An abrupt parent exit closes its lock descriptor before the child exits.
    // The child must keep the lock, or a replacement could rotate concurrently.
    drop(holder);
    assert!(prepare(&home.0).is_err());
    let request = json!({"method": "access", "force": true});
    let reply = owner.request(&home.0, &request).await.unwrap();
    assert!(!reply.to_string().contains("rotated-private"));
    assert!(std::fs::read_to_string(home.0.join("auth.json")).unwrap().contains("rotated-private"));
    let mismatch =
        json!({"method": "access", "force": true, "previousAccountId": "different-account"});
    assert!(owner.request(&home.0, &mismatch).await.is_err());
    assert!(owner.request(&home.0, &json!({"method": "login"})).await.is_err());
    owner.child.kill().await.unwrap();
    owner.child.wait().await.unwrap();
    assert!(prepare(&home.0).is_ok());
}
