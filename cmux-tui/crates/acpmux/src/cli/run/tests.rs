use super::*;
use crate::rpc::{Message, RpcError};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[tokio::test]
async fn missing_peer_session_allows_relay_but_other_rpc_errors_do_not() {
    for (error, should_relay) in [
        (RpcError::not_found("no session matches \"peer/name\""), true),
        (RpcError::invalid_params("ambiguous session"), false),
        (RpcError::internal("credentials not found"), false),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("daemon.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (rd, mut wr) = stream.into_split();
            let mut lines = BufReader::new(rd).lines();
            for expected in [method::INITIALIZE, method::MUX_INFO] {
                let line = lines.next_line().await.unwrap().unwrap();
                let Message::Request { id, method, params } = Message::parse(&line).unwrap() else {
                    panic!("expected request");
                };
                assert_eq!(method, expected);
                let response = if expected == method::INITIALIZE {
                    Message::ok(id, json!({}))
                } else {
                    assert_eq!(params.unwrap()["sessionId"], "peer/name");
                    Message::err(id, error.clone())
                };
                wr.write_all(response.to_line().as_bytes()).await.unwrap();
            }
        });
        let client = Client::connect(&socket).await.unwrap();
        let error = resolve_id(&client, "peer/name").await.unwrap_err();
        server.await.unwrap();
        assert_eq!(crate::cli::send_relay::no_such_session(&error), should_relay, "{error}");
    }
}
