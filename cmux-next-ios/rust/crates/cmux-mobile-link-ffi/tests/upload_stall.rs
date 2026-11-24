//! A receive with no data frame for the stall bound ends as `stalled` and keeps its partial.

mod common;

use cmux_mobile_link_ffi::Transport;
use common::{ask, read_to_close, upload_rig, wait_for_offset};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stalled_upload_ends_and_keeps_its_bytes() {
    cmux_mobile_host::services::set_upload_stall_bound(std::time::Duration::from_millis(800));
    let rig = upload_rig(Transport::WireGuard).await;
    let args = serde_json::json!({"name": "s.bin", "size": "1000", "id": "stall-1"});
    let channel = rig.handle.open_channel("upload".into(), args.to_string()).await.unwrap();
    channel.send(vec![9; 300]).await.unwrap();
    let started = std::time::Instant::now();
    let (reply, code) = read_to_close(&channel).await;
    let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    assert_eq!(reply["error"], "stalled", "{reply}");
    assert_eq!(code, "stalled");
    assert!(started.elapsed() < std::time::Duration::from_secs(10));
    wait_for_offset(&rig, "stall-1", 300).await;
    // And it resumes.
    let args = serde_json::json!({"name": "s.bin", "size": "1000", "id": "stall-1", "offset": "300"});
    let channel = rig.handle.open_channel("upload".into(), args.to_string()).await.unwrap();
    channel.send(vec![9; 700]).await.unwrap();
    let (reply, code) = read_to_close(&channel).await;
    assert_eq!(code, "eof", "{}", String::from_utf8_lossy(&reply));
    let _ = ask;
}
