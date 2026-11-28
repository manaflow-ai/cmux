//! The phone's vault surface against an in-memory server shaped like cmux-platform's
//! `SealedVaultRoute.ts`: turn on, join and approve by code, keep and import values, sync to a
//! machine that opens them; that no value reaches the server or an answer in the clear, that a
//! phone with no key sends nothing, and that requests stop at the budget.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_vault_e2e::b64;
use cmux_vault_e2e::client::{BASE, Http as _};
use cmux_vault_e2e::crypto::{self, DeviceKey, Sealed};
use serde_json::{Value, json};

use super::*;

const VM: &str = "vm_phone000000000000001";
const SECRET: &str = "sk-live-do-not-leak-4242";

#[derive(Default)]
struct Server {
    epoch: u64,
    devices: Vec<Value>,
    wraps: BTreeMap<String, Value>,
    items: BTreeMap<String, Value>,
    deliveries: BTreeMap<String, Vec<Value>>,
    machines: Vec<(String, Vec<u8>)>,
    /// Every request, `METHOD path`, and every body, to check what crossed.
    requests: Vec<String>,
    bodies: Vec<String>,
}

#[derive(Clone, Default)]
struct FakeCloud(Arc<Mutex<Server>>);

#[async_trait::async_trait]
impl VaultHttp for FakeCloud {
    async fn send(&self, request: VaultHttpRequest) -> Result<VaultHttpReply, VaultBridgeError> {
        let mut s = self.0.lock().unwrap();
        s.requests.push(format!("{} {}", request.method, request.path));
        let body: Option<Value> = request.body.as_deref().map(|b| serde_json::from_str(b).unwrap());
        if let Some(text) = &request.body {
            s.bodies.push(text.clone());
        }
        let (route, _) = request.path.split_once('?').unwrap_or((request.path.as_str(), ""));
        let parts: Vec<&str> =
            route.strip_prefix(BASE).unwrap_or(route).split('/').filter(|p| !p.is_empty()).collect();
        let answer = match (request.method.as_str(), parts.as_slice()) {
            ("GET", []) => {
                let mut a = json!({"vault": "personal", "epoch": s.epoch, "devices": s.devices,
                                    "items": s.items.values().collect::<Vec<_>>()});
                if let Some(wrap) = request.device.as_ref().and_then(|d| s.wraps.get(d)) {
                    a["wrap"] = wrap.clone();
                }
                a
            }
            ("POST", ["devices"]) => {
                let body = body.unwrap();
                let id = body["id"].as_str().unwrap().to_owned();
                let active = s.devices.is_empty() && body.get("wrap").is_some();
                if active {
                    s.epoch = 1;
                    s.wraps.insert(id.clone(), body["wrap"].clone());
                }
                s.devices.push(json!({"id": id, "kind": body["kind"], "label": body["label"],
                    "publicKey": body["publicKey"], "state": if active {"active"} else {"pending"}, "createdAt": 1}));
                json!({})
            }
            ("POST", ["devices", target, "approve"]) => {
                let body = body.unwrap();
                s.wraps.insert(
                    (*target).to_owned(),
                    json!({"epoch": body["epoch"], "enc": body["enc"], "ct": body["ct"]}),
                );
                for d in &mut s.devices {
                    if d["id"] == *target {
                        d["state"] = json!("active");
                    }
                }
                json!({})
            }
            ("PUT", ["items", id]) => {
                let mut item = body.unwrap();
                item["id"] = json!(id);
                item["updatedAt"] = json!(2);
                s.items.insert((*id).to_owned(), item);
                json!({})
            }
            ("DELETE", ["items", id]) => {
                s.items.remove(*id);
                json!({})
            }
            ("GET", ["machines"]) => {
                let machines: Vec<Value> = s.machines.iter().map(|(id, key)| {
                    let delivered: Vec<Value> = s.deliveries.get(id).cloned().unwrap_or_default().iter()
                        .map(|d| json!({"name": d["name"], "revision": d["revision"]})).collect();
                    json!({"id": id, "name": "phone-started", "state": "running", "daemonKey": b64::encode(key), "delivered": delivered})
                }).collect();
                json!({"machines": machines})
            }
            ("PUT", ["machines", vm, "delivery"]) => {
                let items = body.unwrap()["items"].as_array().unwrap().clone();
                s.deliveries.insert((*vm).to_owned(), items);
                json!({})
            }
            _ => {
                return Ok(VaultHttpReply {
                    status: 404,
                    body: json!({"error": {"code": "route.not_found", "message": "no"}}).to_string(),
                });
            }
        };
        Ok(VaultHttpReply { status: 200, body: answer.to_string() })
    }
}

/// The Keychain item, in memory.
#[derive(Default)]
struct MemoryKeychain(Mutex<Option<Vec<u8>>>);

impl VaultKeyStore for MemoryKeychain {
    fn load(&self) -> Result<Option<Vec<u8>>, VaultBridgeError> {
        Ok(self.0.lock().unwrap().clone())
    }
    fn save(&self, record: Vec<u8>) -> Result<(), VaultBridgeError> {
        *self.0.lock().unwrap() = Some(record);
        Ok(())
    }
}

fn phone(cloud: &FakeCloud, label: &str) -> (Arc<PhoneVault>, Arc<MemoryKeychain>) {
    let keychain = Arc::new(MemoryKeychain::default());
    (PhoneVault::new(Arc::new(cloud.clone()), keychain.clone(), label.to_owned()), keychain)
}

fn parse(text: &str) -> Value {
    serde_json::from_str(text).unwrap()
}

#[test]
fn the_keychain_record_round_trips_and_a_damaged_one_is_refused() {
    let key = [7_u8; 32];
    let record = encode_record("dev_abc-_1", &key);
    let (id, back) = decode_record(&record).unwrap();
    assert_eq!(id, "dev_abc-_1");
    assert_eq!(back.as_slice(), &key);
    assert!(decode_record(b"dev_x").is_none());
    assert!(decode_record(b"not-a-dev\nAAAA").is_none());
    assert!(decode_record(b"dev_x\nAAAA").is_none(), "a short key is damaged");
}

#[tokio::test]
async fn a_phone_that_never_turned_it_on_sends_nothing_on_sync() {
    let cloud = FakeCloud::default();
    let (vault, keychain) = phone(&cloud, "iPhone");
    let answer = parse(&vault.sync().await.unwrap());
    assert_eq!(answer["outcome"], "off");
    assert!(cloud.0.lock().unwrap().requests.is_empty());
    // Status reads the vault but never makes a key.
    assert_eq!(parse(&vault.status().await.unwrap())["state"], "off");
    assert!(keychain.0.lock().unwrap().is_none());
}

#[tokio::test]
async fn the_phone_turns_it_on_keeps_a_value_and_seals_it_to_a_machine_it_started() {
    let cloud = FakeCloud::default();
    let daemon = DeviceKey::generate().unwrap();
    cloud.0.lock().unwrap().machines.push((VM.to_owned(), daemon.public_bytes().to_vec()));
    let (vault, keychain) = phone(&cloud, "Leo's iPhone");

    let on = parse(&vault.turn_on().await.unwrap());
    assert_eq!(on["state"], "active");
    assert_eq!(on["devices"][0]["kind"], "iphone");
    assert_eq!(on["devices"][0]["label"], "Leo's iPhone");
    assert!(keychain.0.lock().unwrap().is_some());

    let scope = vault_scope("all".into(), String::new()).unwrap();
    vault.set("OPENAI_API_KEY".into(), scope, SECRET.into()).await.unwrap();
    let status = vault.status().await.unwrap();
    assert!(!status.contains(SECRET), "a value never comes back");
    let status = parse(&status);
    assert_eq!(status["items"][0]["name"], "OPENAI_API_KEY");
    assert_eq!(status["items"][0]["masked"], "••••••••");
    assert_eq!(status["items"][0]["scopeLabel"], "every machine");

    let synced = parse(&vault.sync().await.unwrap());
    assert_eq!(synced["outcome"], "done");
    assert_eq!(synced["machines"][0]["outcome"], "delivered");
    // A second sync finds the machine current and seals nothing new.
    assert_eq!(parse(&vault.sync().await.unwrap())["machines"][0]["outcome"], "current");

    let s = cloud.0.lock().unwrap();
    assert!(s.bodies.iter().all(|b| !b.contains(SECRET)), "the server never sees the value");
    let delivered = &s.deliveries[VM][0];
    let sealed = Sealed {
        enc: b64::decode(delivered["enc"].as_str().unwrap()).unwrap(),
        ct: b64::decode(delivered["ct"].as_str().unwrap()).unwrap(),
    };
    let revision = delivered["revision"].as_u64().unwrap();
    let opened =
        crypto::open_delivery(daemon.private_bytes(), VM, "OPENAI_API_KEY", revision, &sealed).unwrap();
    assert_eq!(opened.as_slice(), SECRET.as_bytes());
}

#[tokio::test]
async fn a_second_phone_waits_with_its_code_until_approved() {
    let cloud = FakeCloud::default();
    let (mac, _) = phone(&cloud, "Mac");
    mac.turn_on().await.unwrap();
    let (iphone, _) = phone(&cloud, "iPhone");

    let pending = parse(&iphone.turn_on().await.unwrap());
    assert_eq!(pending["state"], "pending");
    let code = pending["safetyCode"].as_str().unwrap().to_owned();
    assert_eq!(code.chars().filter(char::is_ascii_digit).count(), 8);
    assert_eq!(parse(&iphone.sync().await.unwrap())["outcome"], "pending");

    // The Mac lists it with the same code, and approves it by that code.
    let seen = parse(&mac.status().await.unwrap());
    let listed = seen["devices"].as_array().unwrap().iter().find(|d| d["state"] == "pending").unwrap();
    assert_eq!(listed["safetyCode"], code.as_str());
    assert!(matches!(mac.approve("0000 0000".into()).await, Err(VaultError::Refused { .. })));
    mac.approve(code).await.unwrap();
    assert_eq!(parse(&iphone.status().await.unwrap())["state"], "active");
    assert_eq!(parse(&iphone.sync().await.unwrap())["outcome"], "done");
}

#[tokio::test]
async fn an_import_shows_names_only_and_keeps_only_the_picked_ones() {
    let cloud = FakeCloud::default();
    let (vault, _) = phone(&cloud, "iPhone");
    vault.turn_on().await.unwrap();
    let env =
        format!("# keys\nOPENAI_API_KEY={SECRET}\nexport GITHUB_TOKEN='ghp_x'\nPATH=/bin\nnot a line\n");
    let scope = vault_scope("repo".into(), "Manaflow-AI/cmux".into()).unwrap();
    assert_eq!(scope, "repo:manaflow-ai/cmux");

    let preview = vault.import_preview(env.clone(), scope.clone()).await.unwrap();
    assert!(!preview.contains(SECRET) && !preview.contains("ghp_x"));
    let preview = parse(&preview);
    let names: Vec<&str> =
        preview["rows"].as_array().unwrap().iter().map(|r| r["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["OPENAI_API_KEY", "GITHUB_TOKEN", "PATH"]);
    assert_eq!(preview["rows"][2]["keepable"], false, "PATH is the shell's");
    assert_eq!(preview["skippedLines"], json!([5]));

    let kept = vault.import_names(env, vec!["GITHUB_TOKEN".into()], scope.clone()).await.unwrap();
    assert_eq!(kept, 1);
    let status = parse(&vault.status().await.unwrap());
    assert_eq!(status["items"].as_array().unwrap().len(), 1);
    assert_eq!(status["items"][0]["name"], "GITHUB_TOKEN");
    assert_eq!(status["items"][0]["scope"], "repo:manaflow-ai/cmux");

    assert_eq!(vault.remove("GITHUB_TOKEN".into(), scope).await.unwrap(), 1);
    assert!(parse(&vault.status().await.unwrap())["items"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn bad_names_scopes_and_values_are_refused_before_anything_is_sent() {
    let cloud = FakeCloud::default();
    let (vault, _) = phone(&cloud, "iPhone");
    vault.turn_on().await.unwrap();
    let before = cloud.0.lock().unwrap().requests.len();
    let all = vault_scope("all".into(), String::new()).unwrap();
    for (name, scope, value) in [
        ("PATH", all.as_str(), "x"),
        ("CMUX_TOKEN", all.as_str(), "x"),
        ("GOOD", all.as_str(), ""),
        ("GOOD", "repo:../x", "x"),
    ] {
        assert!(matches!(
            vault.set(name.into(), scope.into(), value.into()).await,
            Err(VaultError::Refused { .. })
        ));
    }
    assert_eq!(cloud.0.lock().unwrap().requests.len(), before);
    assert!(vault_scope("machine".into(), "vm_short".into()).is_none());
    assert_eq!(vault_scope("machine".into(), VM.into()).as_deref(), Some("machine:vm_phone000000000000001"));
    assert!(!vault_valid_name("1BAD".into()));
    assert!(vault_valid_name("STRIPE_KEY".into()));
}

#[test]
fn no_request_is_sent_once_the_budget_ran_out() {
    let cloud = FakeCloud::default();
    let bridge = Bridge {
        http: Arc::new(cloud.clone()),
        runtime: tokio::runtime::Builder::new_current_thread().build().unwrap(),
        deadline: Instant::now() - Duration::from_millis(1),
    };
    assert!(bridge.send("GET", BASE, &[], None).is_err());
    assert!(cloud.0.lock().unwrap().requests.is_empty());
}
