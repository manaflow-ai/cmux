use acpmux_client::ffi::{
    ACPMUX_CLIENT_OK, Bytes, FolderChangeJson, acpmux_client_bytes_free, acpmux_client_connected,
    acpmux_client_free, acpmux_client_new, acpmux_client_next_change, acpmux_client_page,
    acpmux_client_received, acpmux_client_subscribe, acpmux_client_subscribe_mirror,
    acpmux_client_take_send, acpmux_client_unwant, acpmux_client_want,
};
use acpmux_client::wire::{
    FolderPosition, Frame, FrameKind, HelloReply, Limits, ListView, Page, PageSide, Sub,
};

#[test]
fn pointer_length_calls_drive_the_same_core_as_rust() {
    let handle = acpmux_client_new();
    assert!(!handle.is_null());

    unsafe {
        assert_eq!(acpmux_client_connected(handle), ACPMUX_CLIENT_OK);

        let mut outbound = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(acpmux_client_take_send(handle, &mut outbound), ACPMUX_CLIENT_OK);
        assert!(outbound.len > 0);
        acpmux_client_bytes_free(outbound);

        let sub = serde_json::to_vec(&Sub::new("s", "list")).unwrap();
        let mut sid = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(
            acpmux_client_subscribe(handle, sub.as_ptr(), sub.len(), &mut sid),
            ACPMUX_CLIENT_OK
        );
        assert!(sid.len > 0);
        acpmux_client_bytes_free(sid);

        let page = serde_json::to_vec(&Page::new("s", "list", PageSide::After, 1)).unwrap();
        assert_eq!(acpmux_client_page(handle, page.as_ptr(), page.len()), ACPMUX_CLIENT_OK);

        let mut change = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(acpmux_client_next_change(handle, &mut change), ACPMUX_CLIENT_OK);
        assert_eq!(change.len, 0);

        acpmux_client_free(handle);
    }
}

#[test]
fn mirror_and_wanted_calls_match_the_rust_window_change() {
    let handle = acpmux_client_new();
    assert!(!handle.is_null());
    unsafe {
        let request = serde_json::json!({
            "sub": {"sid":"m","stream":"list","view":"live","rows":"v1"},
            "held": [],
            "whole": false
        });
        let request = serde_json::to_vec(&request).unwrap();
        let mut sid = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(
            acpmux_client_subscribe_mirror(handle, request.as_ptr(), request.len(), &mut sid),
            ACPMUX_CLIENT_OK
        );
        acpmux_client_bytes_free(sid);
        let key = serde_json::json!({"origin":"local","chatId":"wanted","lastActivity":1});
        let keys = serde_json::json!({"sid":"m","keys":[key]});
        let keys = serde_json::to_vec(&keys).unwrap();
        assert_eq!(acpmux_client_want(handle, keys.as_ptr(), keys.len()), ACPMUX_CLIENT_OK);
        assert_eq!(acpmux_client_unwant(handle, keys.as_ptr(), keys.len()), ACPMUX_CLIENT_OK);
        assert_eq!(acpmux_client_connected(handle), ACPMUX_CLIENT_OK);

        let mut outbound = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(acpmux_client_take_send(handle, &mut outbound), ACPMUX_CLIENT_OK);
        let upgrade: serde_json::Value =
            serde_json::from_slice(std::slice::from_raw_parts(outbound.ptr, outbound.len)).unwrap();
        let id = upgrade.get("id").cloned().unwrap();
        acpmux_client_bytes_free(outbound);
        let reply = format!("{{\"id\":{id},\"result\":{{\"upgrade\":true}}}}\n");
        let mut consumed = 0;
        assert_eq!(
            acpmux_client_received(handle, reply.as_ptr(), reply.len(), &mut consumed),
            ACPMUX_CLIENT_OK
        );
        let mut hello = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        acpmux_client_take_send(handle, &mut hello);
        acpmux_client_bytes_free(hello);
        let hello = Frame::json(
            FrameKind::Hello,
            &HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        assert_eq!(
            acpmux_client_received(handle, hello.as_ptr(), hello.len(), &mut consumed),
            ACPMUX_CLIENT_OK
        );
        let mut sub = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        acpmux_client_take_send(handle, &mut sub);
        acpmux_client_bytes_free(sub);
        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"m","cursor":4,"rows":[{
                "chatId":"chat","title":"Chat","harness":"claude","state":"idle",
                "lastActivity":4,"unread":0,"workspace":null,"origin":"local","pinned":false,
                "archived":false,"parent":null,"forkOf":null,"folder":null,"extra":{"custom":true}
            }],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        acpmux_client_received(handle, window.as_ptr(), window.len(), &mut consumed);
        let mut change = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        acpmux_client_next_change(handle, &mut change);
        let c_value: serde_json::Value =
            serde_json::from_slice(std::slice::from_raw_parts(change.ptr, change.len)).unwrap();
        let mut rust = acpmux_client::Client::<serde_json::Value>::connected_v2();
        let hello = Frame::json(
            FrameKind::Hello,
            &HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        rust.received(&hello);
        let mut rust_sub = Sub::new("m", "list");
        rust_sub.rows = Some("v1".into());
        rust.subscribe_mirror(rust_sub, std::iter::empty(), false).unwrap();
        rust.received(&window);
        let expected = match rust.next_change().unwrap() {
            acpmux_client::Change::Window(window) => serde_json::to_value(window).unwrap(),
            other => panic!("unexpected change: {other:?}"),
        };
        assert_eq!(c_value, expected);
        acpmux_client_bytes_free(change);
        acpmux_client_free(handle);
    }
}

#[test]
fn folder_changes_are_readable_through_the_ffi_json_surface() {
    let handle = acpmux_client_new();
    assert!(!handle.is_null());

    unsafe {
        assert_eq!(acpmux_client_connected(handle), ACPMUX_CLIENT_OK);
        let mut outbound = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        acpmux_client_take_send(handle, &mut outbound);
        let upgrade: serde_json::Value =
            serde_json::from_slice(std::slice::from_raw_parts(outbound.ptr, outbound.len)).unwrap();
        let id = upgrade.get("id").cloned().unwrap();
        acpmux_client_bytes_free(outbound);

        let reply = format!("{{\"id\":{id},\"result\":{{\"upgrade\":true}}}}\n");
        let mut consumed = 0;
        assert_eq!(
            acpmux_client_received(handle, reply.as_ptr(), reply.len(), &mut consumed),
            ACPMUX_CLIENT_OK
        );
        let mut hello_request = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        acpmux_client_take_send(handle, &mut hello_request);
        acpmux_client_bytes_free(hello_request);
        let hello = Frame::json(
            FrameKind::Hello,
            &HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        assert_eq!(
            acpmux_client_received(handle, hello.as_ptr(), hello.len(), &mut consumed),
            ACPMUX_CLIENT_OK
        );

        let mut sub = Sub::new("folders", "list");
        sub.view = Some(ListView::Folders);
        let sub_bytes = serde_json::to_vec(&sub).unwrap();
        let mut sid = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(
            acpmux_client_subscribe(handle, sub_bytes.as_ptr(), sub_bytes.len(), &mut sid),
            ACPMUX_CLIENT_OK
        );
        acpmux_client_bytes_free(sid);
        let mut request = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(acpmux_client_take_send(handle, &mut request), ACPMUX_CLIENT_OK);
        acpmux_client_bytes_free(request);

        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({
                "sid":"folders","cursor":1,"rows":[],"hasBefore":false,
                "hasAfter":false,"edition":1
            }),
        )
        .unwrap()
        .encode();
        assert_eq!(
            acpmux_client_received(handle, window.as_ptr(), window.len(), &mut consumed),
            ACPMUX_CLIENT_OK
        );
        let mut change = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(acpmux_client_next_change(handle, &mut change), ACPMUX_CLIENT_OK);
        assert!(!change.ptr.is_null() && change.len > 0);
        let value: serde_json::Value =
            serde_json::from_slice(std::slice::from_raw_parts(change.ptr, change.len)).unwrap();
        let decoded: FolderChangeJson = serde_json::from_value(value.clone()).unwrap();
        assert!(
            matches!(decoded, FolderChangeJson::FolderWindow { window } if window.rows.is_empty())
        );
        assert_eq!(value.get("kind"), Some(&serde_json::Value::String("folderWindow".into())));
        assert_eq!(value.get("sid"), Some(&serde_json::Value::String("folders".into())));
        assert_eq!(value.get("cursor"), Some(&serde_json::Value::from(1u64)));
        acpmux_client_bytes_free(change);

        let page = Page::new_folder(
            "folders",
            "list",
            PageSide::After,
            FolderPosition { at: 1, origin: "local".into(), folder: "/work".into() },
        );
        let page_bytes = serde_json::to_vec(&page).unwrap();
        assert_eq!(
            acpmux_client_page(handle, page_bytes.as_ptr(), page_bytes.len()),
            ACPMUX_CLIENT_OK
        );
        let mut request = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(acpmux_client_take_send(handle, &mut request), ACPMUX_CLIENT_OK);
        acpmux_client_bytes_free(request);
        let folder_page = Frame::json(
            FrameKind::Page,
            &serde_json::json!({
                "sid":"folders","rows":[],"hasBefore":false,"hasAfter":false
            }),
        )
        .unwrap()
        .encode();
        acpmux_client_received(handle, folder_page.as_ptr(), folder_page.len(), &mut consumed);
        let mut change = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(acpmux_client_next_change(handle, &mut change), ACPMUX_CLIENT_OK);
        assert!(!change.ptr.is_null() && change.len > 0);
        let value: serde_json::Value =
            serde_json::from_slice(std::slice::from_raw_parts(change.ptr, change.len)).unwrap();
        let decoded: FolderChangeJson = serde_json::from_value(value.clone()).unwrap();
        assert!(matches!(decoded, FolderChangeJson::FolderPage { page } if page.rows.is_empty()));
        assert_eq!(value.get("kind"), Some(&serde_json::Value::String("folderPage".into())));
        assert_eq!(value.pointer("/page/sid"), Some(&serde_json::Value::String("folders".into())));
        acpmux_client_bytes_free(change);

        let row = serde_json::json!({
            "origin":"local", "folder":"/work",
            "newest":{"origin":"local","chatId":"chat"}, "at":2, "count":1
        });
        let delta = Frame::json(
            FrameKind::Delta,
            &serde_json::json!({"sid":"folders","ops":[
                {"op":"folder","seq":2,"row":row},
                {"op":"folderGone","seq":3,"origin":"local","folder":"/work"}
            ]}),
        )
        .unwrap()
        .encode();
        acpmux_client_received(handle, delta.as_ptr(), delta.len(), &mut consumed);
        let mut change = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(acpmux_client_next_change(handle, &mut change), ACPMUX_CLIENT_OK);
        assert!(!change.ptr.is_null() && change.len > 0);
        let value: serde_json::Value =
            serde_json::from_slice(std::slice::from_raw_parts(change.ptr, change.len)).unwrap();
        let decoded: FolderChangeJson = serde_json::from_value(value.clone()).unwrap();
        assert!(matches!(decoded, FolderChangeJson::Folder { seq: 2, .. }));
        assert_eq!(value.get("kind"), Some(&serde_json::Value::String("folder".into())));
        assert_eq!(value.get("seq"), Some(&serde_json::Value::from(2u64)));
        acpmux_client_bytes_free(change);
        let mut change = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(acpmux_client_next_change(handle, &mut change), ACPMUX_CLIENT_OK);
        assert!(!change.ptr.is_null() && change.len > 0);
        let value: serde_json::Value =
            serde_json::from_slice(std::slice::from_raw_parts(change.ptr, change.len)).unwrap();
        let decoded: FolderChangeJson = serde_json::from_value(value.clone()).unwrap();
        assert!(matches!(decoded, FolderChangeJson::FolderGone { seq: 3, .. }));
        assert_eq!(value.get("kind"), Some(&serde_json::Value::String("folderGone".into())));
        assert_eq!(value.get("seq"), Some(&serde_json::Value::from(3u64)));
        assert_eq!(value.get("origin"), Some(&serde_json::Value::String("local".into())));
        acpmux_client_bytes_free(change);
        acpmux_client_free(handle);
    }
}

unsafe fn take_json(handle: *mut std::ffi::c_void) -> serde_json::Value {
    let mut change = Bytes { ptr: std::ptr::null_mut(), len: 0 };
    assert_eq!(unsafe { acpmux_client_next_change(handle, &mut change) }, ACPMUX_CLIENT_OK);
    assert!(change.len > 0);
    let value =
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(change.ptr, change.len) })
            .unwrap();
    unsafe { acpmux_client_bytes_free(change) };
    value
}

unsafe fn sent_requests(handle: *mut std::ffi::c_void) -> Vec<serde_json::Value> {
    let mut out = Vec::new();
    loop {
        let mut bytes = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(unsafe { acpmux_client_take_send(handle, &mut bytes) }, ACPMUX_CLIENT_OK);
        if bytes.len == 0 {
            return out;
        }
        let encoded = unsafe { std::slice::from_raw_parts(bytes.ptr, bytes.len) };
        if let Ok(frame) = Frame::from_encoded(encoded) {
            out.push(frame.decode_json().unwrap());
        } else {
            out.push(serde_json::from_slice(encoded).unwrap());
        }
        unsafe { acpmux_client_bytes_free(bytes) };
    }
}

unsafe fn give(handle: *mut std::ffi::c_void, bytes: &[u8]) -> usize {
    let mut consumed = 0;
    assert_eq!(
        unsafe { acpmux_client_received(handle, bytes.as_ptr(), bytes.len(), &mut consumed) },
        ACPMUX_CLIENT_OK
    );
    consumed
}

#[test]
fn one_handle_carries_a_chat_through_each_c_function() {
    use acpmux_client::ffi::{
        ACPMUX_CLIENT_ABI_VERSION, acpmux_client_abi_version, acpmux_client_chat_blob,
        acpmux_client_chat_page, acpmux_client_new_with_surfaces, acpmux_client_subscribe_chat,
        acpmux_client_unsubscribe,
    };
    use acpmux_client::wire::{BlobHead, blob_frame};

    assert_eq!(acpmux_client_abi_version(), ACPMUX_CLIENT_ABI_VERSION);
    assert_eq!(ACPMUX_CLIENT_ABI_VERSION, 3);
    let surfaces = br#"["list","chat"]"#;
    assert!(unsafe { acpmux_client_new_with_surfaces(b"{".as_ptr(), 1) }.is_null());
    let handle = unsafe { acpmux_client_new_with_surfaces(surfaces.as_ptr(), surfaces.len()) };
    assert!(!handle.is_null());
    unsafe {
        let request =
            br#"{"sid":"c","chat":"c1","anchor":{"rowId":7,"side":"around"},"window":50}"#;
        let mut sid = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(
            acpmux_client_subscribe_chat(handle, request.as_ptr(), request.len(), &mut sid),
            ACPMUX_CLIENT_OK
        );
        assert_eq!(std::slice::from_raw_parts(sid.ptr, sid.len), br#"{"sid":"c"}"#);
        acpmux_client_bytes_free(sid);
        let list = serde_json::to_vec(&Sub::new("l", "list")).unwrap();
        let mut sid = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(
            acpmux_client_subscribe(handle, list.as_ptr(), list.len(), &mut sid),
            ACPMUX_CLIENT_OK
        );
        acpmux_client_bytes_free(sid);

        assert_eq!(acpmux_client_connected(handle), ACPMUX_CLIENT_OK);
        let upgrade = sent_requests(handle).pop().unwrap();
        assert_eq!(upgrade["params"]["surfaces"], serde_json::json!(["list", "chat"]));
        let reply = format!("{{\"id\":{},\"result\":{{\"upgrade\":true}}}}\n", upgrade["id"]);
        give(handle, reply.as_bytes());
        sent_requests(handle);
        let hello = Frame::json(
            FrameKind::Hello,
            &HelloReply { daemon_id: "d".into(), limits: Limits::default() },
        )
        .unwrap()
        .encode();
        give(handle, &hello);
        let subs = sent_requests(handle);
        let chat_sub = subs.iter().find(|sub| sub["params"]["sid"] == "c").unwrap();
        assert_eq!(chat_sub["params"]["stream"], "chat:c1");
        assert_eq!(chat_sub["params"]["anchor"], serde_json::json!({"rowId":7,"side":"around"}));

        let window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"c","cursor":9,"edition":3,"rows":[{"id":7}],
                "hasBefore":true,"hasAfter":false}),
        )
        .unwrap()
        .encode();
        // A caller that takes no change stops the socket.
        assert_eq!(give(handle, &window), window.len());
        assert_eq!(give(handle, &window), 0);
        let change = take_json(handle);
        assert_eq!(change["kind"], "chatWindow");
        assert_eq!(change["replaces"], true);
        assert_eq!(change["window"]["rows"], serde_json::json!([{"id":7}]));

        let page = br#"{"sid":"c","before":7}"#;
        assert_eq!(acpmux_client_chat_page(handle, page.as_ptr(), page.len()), ACPMUX_CLIENT_OK);
        let request = sent_requests(handle).pop().unwrap();
        assert_eq!(request["params"]["edition"], 3);
        let reply = Frame::json(
            FrameKind::Page,
            &serde_json::json!({"sid":"c","edition":3,"rows":[{"id":6}],"hasBefore":false,"hasAfter":true}),
        )
        .unwrap()
        .encode();
        give(handle, &reply);
        assert_eq!(take_json(handle)["kind"], "chatPage");

        let blob = br#"{"sid":"c","rowId":7,"len":8}"#;
        let mut id = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        assert_eq!(
            acpmux_client_chat_blob(handle, blob.as_ptr(), blob.len(), &mut id),
            ACPMUX_CLIENT_OK
        );
        let id_value: serde_json::Value =
            serde_json::from_slice(std::slice::from_raw_parts(id.ptr, id.len)).unwrap();
        acpmux_client_bytes_free(id);
        let id = id_value["id"].as_str().unwrap().to_owned();
        assert_eq!(sent_requests(handle).pop().unwrap()["params"]["id"], id.as_str());
        let head = BlobHead {
            id: id.clone(),
            start: 0,
            len: 4,
            total: 4,
            next: None,
            open: false,
            generation: None,
            fixed: None,
        };
        give(handle, &blob_frame(&head, b"{\"a\"").unwrap().encode());
        let mut change = Bytes { ptr: std::ptr::null_mut(), len: 0 };
        acpmux_client_next_change(handle, &mut change);
        let bytes = std::slice::from_raw_parts(change.ptr, change.len).to_vec();
        acpmux_client_bytes_free(change);
        let newline = bytes.iter().position(|byte| *byte == b'\n').unwrap();
        let json: serde_json::Value = serde_json::from_slice(&bytes[..newline]).unwrap();
        assert_eq!(json["kind"], "chatBlob");
        assert_eq!(json["head"]["id"], id.as_str());
        assert_eq!(json["nextStart"], 4);
        assert_eq!(&bytes[newline + 1..], b"{\"a\"");

        let unsub = br#""c""#;
        assert_eq!(
            acpmux_client_unsubscribe(handle, unsub.as_ptr(), unsub.len()),
            ACPMUX_CLIENT_OK
        );
        assert_eq!(
            sent_requests(handle),
            vec![serde_json::json!({"method":"unsub","params":{"sid":"c"}})]
        );
        // The list sub stays.
        let list_window = Frame::json(
            FrameKind::Window,
            &serde_json::json!({"sid":"l","cursor":1,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
        )
        .unwrap()
        .encode();
        give(handle, &list_window);
        assert_eq!(take_json(handle)["sid"], "l");
        acpmux_client_free(handle);
    }
}
