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
            "sub": {"sid":"m","stream":"list","view":"live"},
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
            &serde_json::json!({"sid":"m","cursor":4,"rows":[],"hasBefore":false,"hasAfter":false,"edition":1}),
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
        rust.subscribe_mirror(Sub::new("m", "list"), std::iter::empty(), false).unwrap();
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
