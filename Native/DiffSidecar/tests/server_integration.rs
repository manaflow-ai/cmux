use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};

use futures_util::{SinkExt, StreamExt};

#[test]
fn serves_only_manifest_allowlisted_files() {
    let root = std::env::temp_dir().join(format!(
        "cmux-diff-sidecar-test-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&root).expect("create root");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
            .expect("secure root permissions");
    }
    let token = "0123456789abcdef";
    let patch_path = root.join("sample.patch");
    std::fs::write(&patch_path, b"diff --git a/a b/a\n").expect("write patch");
    let manifest = serde_json::json!({
        "token": token,
        "files": [{
            "request_path": "/sample.patch",
            "file_path": patch_path,
            "mime_type": "text/x-diff"
        }]
    });
    std::fs::write(
        root.join(format!(".manifest-{token}.json")),
        serde_json::to_vec(&manifest).expect("encode manifest"),
    )
    .expect("write manifest");

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-diff-sidecar"))
        .arg("serve")
        .arg("--root")
        .arg(&root)
        .arg("--cmux")
        .arg(env!("CARGO_BIN_EXE_diff-sidecar-test-host"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start sidecar");
    let stdout = child.stdout.take().expect("sidecar stdout");
    let mut reader = BufReader::new(stdout);
    let mut port = String::new();
    reader.read_line(&mut port).expect("read port");
    let port = port.trim().parse::<u16>().expect("valid port");
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let client = reqwest::Client::new();
        verify_resources(&client, port, token).await;
        verify_rpc(&client, port, token, &root).await;
        verify_websocket(port).await;
    });
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(root);
}

async fn verify_resources(client: &reqwest::Client, port: u16, token: &str) {
    let health = client
        .get(format!(
            "http://127.0.0.1:{port}/__cmux_diff_viewer_healthz"
        ))
        .send()
        .await
        .expect("health request");
    assert_eq!(health.status(), reqwest::StatusCode::OK);
    assert_eq!(
        health.text().await.expect("health body"),
        cmux_diff_sidecar::health_response()
    );
    let patch = client
        .get(format!("http://127.0.0.1:{port}/{token}/sample.patch"))
        .send()
        .await
        .expect("patch request");
    assert_eq!(patch.status(), reqwest::StatusCode::OK);
    assert_eq!(
        patch.bytes().await.expect("patch body").as_ref(),
        b"diff --git a/a b/a\n"
    );
    let denied = client
        .get(format!("http://127.0.0.1:{port}/{token}/not-allowed.patch"))
        .send()
        .await
        .expect("denied request");
    assert_eq!(denied.status(), reqwest::StatusCode::NOT_FOUND);
}

async fn verify_rpc(client: &reqwest::Client, port: u16, token: &str, root: &Path) {
    let branch_request = serde_json::json!({
        "id": "branches",
        "version": 1,
        "method": "branchList",
        "params": {
            "repoRoot": root,
            "capabilityToken": token,
            "selectedBase": "main"
        }
    });
    let branches = client
        .post(format!("http://127.0.0.1:{port}/__cmux_diff_rpc"))
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(branch_request.to_string())
        .send()
        .await
        .expect("branch list request");
    let branch_bytes = branches.bytes().await.expect("branch list response");
    let branches: serde_json::Value =
        serde_json::from_slice(&branch_bytes).expect("branch list JSON");
    assert_eq!(branches["result"]["type"], "branches");
    assert_eq!(
        branches["result"]["value"]["groups"][0]["rows"][0]["ref"],
        "main"
    );
}

async fn verify_websocket(port: u16) {
    let (mut socket, _) =
        tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/__cmux_diff_ws"))
            .await
            .expect("WebSocket connect");
    socket
        .send(tokio_tungstenite::tungstenite::Message::Text(
            r#"{"id":"hello","version":1,"method":"protocolHandshake"}"#.into(),
        ))
        .await
        .expect("WebSocket handshake request");
    let response = socket
        .next()
        .await
        .expect("WebSocket response")
        .expect("valid WebSocket response")
        .into_text()
        .expect("text response");
    let response: serde_json::Value = serde_json::from_str(&response).expect("JSON response");
    assert_eq!(response["id"], "hello");
    assert_eq!(response["result"]["value"]["protocolVersion"], 1);
}
