//! acpmux's sign-in output parser and write-journal read check as a component. The logic is not
//! copied: the two modules below are acpmux's own files, so editing them and rebuilding this crate
//! is the whole edit loop for a live daemon (../src/lib.rs).

mod bindings {
    wit_bindgen::generate!({ path: "../wit", world: "hot" });
}

/// The `Agent` that `parse.rs` names as `super::Agent`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Agent {
    Claude,
    Codex,
}

#[allow(dead_code)]
#[path = "../../../acpmux/src/agent_login/parse.rs"]
mod parse;

#[allow(dead_code)]
#[path = "../../../acpmux/src/write_journal/classify.rs"]
mod classify;

struct Hot;

impl bindings::Guest for Hot {
    fn abi_version() -> u32 {
        1
    }

    fn is_pure_read(command: String) -> bool {
        if cfg!(feature = "trap") {
            // A wasm trap, as a guest panic would be (panic = "abort").
            core::arch::wasm32::unreachable();
        }
        if cfg!(feature = "spin") {
            let mut n: u64 = 0;
            loop {
                n = std::hint::black_box(n.wrapping_add(1));
            }
        }
        let read = classify::is_pure_read(&command);
        // `v2` answers the same; its marker is a command only it calls a read, so a test can see
        // which module answered.
        if cfg!(feature = "v2") && command == "acpmux-hot-v2-marker" {
            return true;
        }
        read
    }

    fn login_offer(agent: bindings::Agent, output: String) -> Option<bindings::Offer> {
        let agent = match agent {
            bindings::Agent::Claude => Agent::Claude,
            bindings::Agent::Codex => Agent::Codex,
        };
        parse::offer(agent, &output).map(|o| bindings::Offer { url: o.url, user_code: o.user_code })
    }
}

bindings::export!(Hot with_types_in bindings);
