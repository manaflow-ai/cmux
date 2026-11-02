//! `acpmux session detach NAME`: the session's turns stop showing in the chat of the session
//! that started it (`_acpmux/detach_parent`, `hub/lane_detach.rs`).

use crate::cli::output::print_json;
use crate::cli::run::resolve_id;
use crate::daemon::connect;
use crate::rpc::method;
use anyhow::Result;
use serde_json::json;

pub(crate) async fn run(session: &str, json_out: bool) -> Result<()> {
    let client = connect(true).await?;
    let id = resolve_id(&client, session).await?;
    let v = client.request(method::MUX_DETACH_PARENT, json!({"sessionId": id})).await?;
    if json_out {
        print_json(&v)
    } else if v["detached"] == true {
        println!("detached")
    } else {
        println!("no parent: its turns go to no session's chat")
    }
    Ok(())
}
