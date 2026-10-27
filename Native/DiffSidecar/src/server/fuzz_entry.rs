//! The sidecar's decoders of outside input, for the libFuzzer targets in
//! `Native/DiffSidecar/fuzz` (feature `fuzz`, never in a shipped build). Each
//! entry runs the shipped function on bytes, with no process, file or socket.

use super::file_contents::patch_text_names_all;
use super::{RpcRequestRead, decode_rpc_request};
use crate::protocol::{DiffRequest, DiffResponse};

/// One `rpc` stdin request as the sidecar decodes it: the request, or the
/// response that rejects it.
///
/// # Errors
///
/// The rejecting response when `input` is too large or not a `DiffRequest`.
pub fn rpc_request(input: &[u8]) -> Result<DiffRequest, Box<DiffResponse>> {
    match decode_rpc_request(input) {
        RpcRequestRead::Request(request) => Ok(request),
        RpcRequestRead::Rejected(response) => Err(Box::new(response)),
    }
}

/// Whether `patch` names every path of `wanted` in a file header, as
/// `fileContents` decides which paths a session may read.
#[must_use]
pub fn patch_names_all(patch: &[u8], wanted: &[String]) -> bool {
    patch_text_names_all(patch, wanted)
}
