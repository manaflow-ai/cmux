mod common;

use cmux::{MachineId, MachineReadOptions};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

const OWNER: &str = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

#[test]
fn cmux_next_machine_sdk_catalog_opt_in_preserves_default_frames_and_owner_routes() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let capture = seen.clone();
    let peer = common::mock(move |stream, reader| {
        for index in 0..6 {
            let operation = if index < 3 { "machine.list" } else { "machine.get" };
            let request = common::request(reader, operation);
            let mut owner = json!({"id":OWNER,"name":"owner","origin":"local","status":"running",
                "connectable":true,"deleted":false,"recoverable":false});
            if request["params"]["catalog"] == true {
                owner["platform"] = json!({"os":"linux","arch":"aarch64"});
                owner["capabilities"] = json!(["terminal"]);
            }
            let result = if index < 3 { json!([owner]) } else { owner };
            common::read_ok(stream, &request, result);
            capture.lock().unwrap().push(request);
        }
    });
    let client = peer.client();
    client.machines().unwrap();
    client.machines_with(MachineReadOptions { catalog: true }).unwrap();
    client.machines_with(MachineReadOptions::default()).unwrap();
    let owner = client.machine(MachineId::parse(OWNER).unwrap());
    owner.refresh().unwrap();
    let rich = owner.refresh_with(MachineReadOptions { catalog: true }).unwrap();
    owner.refresh_with(MachineReadOptions::default()).unwrap();
    drop(owner);
    drop(client);
    peer.finish();
    let requests = seen.lock().unwrap();
    for (index, request) in requests.iter().enumerate() {
        let mut expected = if index < 3 { json!({}) } else { json!({"machine":OWNER}) };
        if index == 1 || index == 4 {
            expected["catalog"] = Value::Bool(true);
        }
        assert_eq!(request["params"], expected, "wire request {index}");
        assert!(request.get("idempotency_key").is_none());
    }
    assert_eq!(requests.len(), 6);
    assert_eq!(rich.platform.unwrap().os.as_deref(), Some("linux"));
}

#[test]
fn cmux_next_machine_sdk_catalog_opt_in_returns_list_metadata_without_extra_reads() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let capture = seen.clone();
    let peer = common::mock(move |stream, reader| {
        let request = common::request(reader, "machine.list");
        common::read_ok(
            stream,
            &request,
            json!([{
                "id":OWNER,"name":"owner","origin":"server","status":"running",
                "connectable":true,"deleted":false,"recoverable":false,
                "platform":{"os":"linux"},"capabilities":["terminal"]
            }]),
        );
        capture.lock().unwrap().push(request);
    });
    let client = peer.client();
    let rows = client.machine_snapshots_with(MachineReadOptions { catalog: true }).unwrap();
    drop(client);
    peer.finish();
    let requests = seen.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["params"], json!({"catalog":true}));
    assert_eq!(rows[0].platform.as_ref().unwrap().os.as_deref(), Some("linux"));
    assert_eq!(rows[0].capabilities, vec!["terminal"]);
}
