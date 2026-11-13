use acpmux_book::index::{Summary, SummaryIndex};
use acpmux_client::{Change, Client};
use acpmux_core::conn::{self, HubSource};
use acpmux_core::hub::Hub;
use acpmux_core::wire::{self, Frame, FrameKind, Sub};
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, DuplexStream};

async fn read_frame(reader: &mut (impl AsyncRead + Unpin)) -> Frame {
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut header = [0_u8; 4];
        reader.read_exact(&mut header).await.unwrap();
        let len = u32::from_be_bytes(header) as usize;
        let mut bytes = header.to_vec();
        bytes.resize(len + 4, 0);
        reader.read_exact(bytes.get_mut(4..).unwrap()).await.unwrap();
        Frame::from_encoded(&bytes).unwrap()
    })
    .await
    .unwrap()
}

async fn send_bytes(writer: &mut (impl AsyncWrite + Unpin), bytes: Vec<u8>) {
    writer.write_all(&bytes).await.unwrap();
}

fn pair(hub: Arc<Hub>) -> (DuplexStream, tokio::task::JoinHandle<Result<(), conn::ConnError>>) {
    let (client, server) = tokio::io::duplex(4096);
    let source = Arc::new(HubSource::new(hub));
    let (reader, writer) = tokio::io::split(server);
    let task =
        tokio::spawn(
            async move { conn::run(reader, writer, source, "test", &["list".into()]).await },
        );
    (client, task)
}

async fn hello<T>(client: &mut Client<T>, stream: &mut DuplexStream)
where
    T: serde::Serialize + for<'de> serde::Deserialize<'de> + Clone,
{
    send_bytes(stream, client.take_send().unwrap()).await;
    let frame = read_frame(stream).await;
    assert_eq!(frame.kind, FrameKind::Hello);
    let encoded = frame.encode();
    assert_eq!(client.received(&encoded), encoded.len());
}

#[tokio::test]
async fn client_and_daemon_resume_after_a_disconnect() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    writer.apply(Summary::new("chat")).unwrap();
    let hub = Arc::new(hub);
    let mut client = Client::<Summary>::connected_v2();
    let (mut stream, task) = pair(hub.clone());
    hello(&mut client, &mut stream).await;
    client.subscribe(Sub::new("s", "list")).unwrap();
    send_bytes(&mut stream, client.take_send().unwrap()).await;
    let window = read_frame(&mut stream).await;
    let encoded = window.encode();
    client.received(&encoded);
    assert!(matches!(client.next_change(), Some(Change::Window(_))));
    drop(stream);
    task.await.unwrap().unwrap();

    writer.apply(Summary::new("chat-2")).unwrap();
    client.disconnected();
    let (mut stream, task) = pair(hub);
    hello(&mut client, &mut stream).await;
    let request = client.take_send().unwrap();
    let frame = Frame::from_encoded(&request).unwrap();
    assert_eq!(frame.kind, FrameKind::Request);
    let value: Value = frame.decode_json().unwrap();
    assert_eq!(value.get("method"), Some(&Value::String("sub".into())));
    assert_eq!(value.pointer("/params/cursor"), Some(&Value::from(0_u64)));
    send_bytes(&mut stream, request).await;
    let first = read_frame(&mut stream).await;
    assert!(matches!(first.kind, FrameKind::Window | FrameKind::Delta));
    drop(stream);
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn client_reconnect_before_first_window_keeps_anchor() {
    let (hub, _writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    let mut client = Client::<Summary>::connected_v2();
    let (mut stream, task) = pair(hub.clone());
    hello(&mut client, &mut stream).await;
    client.subscribe(Sub::new("s", "list").around(wire::Anchor::End, 10)).unwrap();
    let request = client.take_send().unwrap();
    drop(stream);
    task.await.unwrap().unwrap();
    client.disconnected();
    let (mut stream, task) = pair(hub);
    hello(&mut client, &mut stream).await;
    let request = client.take_send().unwrap_or(request);
    let frame = Frame::from_encoded(&request).unwrap();
    let value: Value = frame.decode_json().unwrap();
    assert_eq!(value.pointer("/params/anchor"), Some(&Value::String("end".into())));
    assert!(value.pointer("/params/cursor").is_none());
    drop(stream);
    task.await.unwrap().unwrap();
}
