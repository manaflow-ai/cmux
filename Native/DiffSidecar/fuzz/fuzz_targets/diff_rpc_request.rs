//! The `rpc` stdin request decoder (server.rs `decode_rpc_request`). Any bytes
//! decode to a request or to a rejection the sidecar can send, and a decoded
//! request encodes back to one that decodes the same: the TypeScript client's
//! types are generated from these serde shapes (bin/generate_types.rs), so an
//! encoding the decoder refuses is a protocol bug.
#![no_main]

use cmux_diff_sidecar::server::fuzz_entry;
use libfuzzer_sys::fuzz_target;

fn error_code(response: &cmux_diff_sidecar::protocol::DiffResponse) -> Option<&str> {
    response.error.as_ref().map(|error| error.code.as_str())
}

fuzz_target!(|data: &[u8]| {
    match fuzz_entry::rpc_request(data) {
        Ok(request) => {
            let encoded = serde_json::to_vec(&request).expect("a decoded request encodes");
            match fuzz_entry::rpc_request(&encoded) {
                Ok(again) => {
                    assert_eq!(again.id, request.id);
                    assert_eq!(again.version, request.version);
                    let encoded_again =
                        serde_json::to_vec(&again).expect("a decoded request encodes");
                    assert_eq!(encoded_again, encoded, "the encoding is stable");
                }
                // `null` for an absent optional field can grow a request past the limit.
                Err(response) => assert_eq!(error_code(&response), Some("requestTooLarge")),
            }
        }
        Err(response) => {
            assert!(response.result.is_none());
            assert!(matches!(
                error_code(&response),
                Some("requestTooLarge" | "invalidRequest")
            ));
            serde_json::to_vec(&response).expect("a rejection encodes");
        }
    }
});
