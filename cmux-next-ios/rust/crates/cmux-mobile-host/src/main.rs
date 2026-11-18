//! `cmux-mobile-host`: the Mac side of cmux-next-ios links. Its command line is
//! [`cmux_mobile_host::entry::run`], which the cmux-next app's bin/cmux also
//! runs by argv[0] (CMUX-570); this binary stays for the Linux tree, the
//! tests and builds without the fold.

fn main() -> std::process::ExitCode {
    cmux_mobile_host::entry::run(std::env::args().skip(1).collect())
}
