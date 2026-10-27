//! cmux-mobile-host's `sf/1` reader (`surface.rs` `SourceDeframer`): the
//! bytes the app's simulator surface source sends to hostd, fed in the
//! input's own chunk sizes, as `host_session` reads its socket.
//!
//! Invariants past "no panic": a frame it returns is under the frame limit
//! and encodes back to bytes the deframer reads as one frame of the same
//! kind; an access unit comes back bit for bit. (A JSON frame is compared by
//! kind only: serde_json's default float parsing is not correctly rounded,
//! so a number may move by one ulp on the way.)
#![no_main]

use cmux_mobile_host::surface::{MAX_SOURCE_FRAME, SourceDeframer, SourceFrame};
use libfuzzer_sys::fuzz_target;

/// The most frames one input reads.
const MAX_FRAMES: usize = 256;

fuzz_target!(|data: &[u8]| {
    let mut deframer = SourceDeframer::default();
    let mut frames = 0;
    let mut rest = data;
    // A length byte, then that many bytes (0 takes the rest): one read.
    while let Some((&len, tail)) = rest.split_first() {
        let len = if len == 0 { tail.len() } else { usize::from(len).min(tail.len()) };
        let (chunk, tail) = tail.split_at(len);
        rest = tail;
        deframer.extend(chunk);
        loop {
            match deframer.next_frame() {
                Ok(Some(frame)) => {
                    let bytes = frame.encode();
                    assert!(bytes.len() <= MAX_SOURCE_FRAME + 5, "a frame past the limit");
                    let mut again = SourceDeframer::default();
                    again.extend(&bytes);
                    match (&frame, again.next_frame()) {
                        (SourceFrame::Json(_), Ok(Some(SourceFrame::Json(_)))) => {}
                        (SourceFrame::AccessUnit { .. }, Ok(Some(back))) => {
                            assert_eq!(back, frame, "an access unit changed on its way back");
                        }
                        (_, back) => panic!("{frame:?} read back as {back:?}"),
                    }
                    assert_eq!(again.next_frame(), Ok(None), "one frame read back as two");
                    frames += 1;
                    if frames >= MAX_FRAMES {
                        return;
                    }
                }
                Ok(None) => break,
                // hostd ends the session on a frame no source may send.
                Err(_) => return,
            }
        }
    }
});
