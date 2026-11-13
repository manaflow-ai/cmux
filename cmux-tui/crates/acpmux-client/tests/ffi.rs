use acpmux_client::ffi::{
    ACPMUX_CLIENT_OK, Bytes, acpmux_client_bytes_free, acpmux_client_connected, acpmux_client_free,
    acpmux_client_new, acpmux_client_next_change, acpmux_client_page, acpmux_client_subscribe,
    acpmux_client_take_send,
};
use acpmux_client::wire::{Page, PageSide, Sub};

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
