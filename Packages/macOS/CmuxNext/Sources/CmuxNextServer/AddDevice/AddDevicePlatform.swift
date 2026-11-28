/// The kind of new device the "Set up a new device" way shows the line for.
public nonisolated enum AddDevicePlatform: String, CaseIterable, Equatable, Sendable {
    /// A Mac or a Linux computer (one shell line).
    case macOrLinux
    case windows
    /// An iPhone: no line; the phone signs in and asks to connect.
    case phone

    /// The line to run on the new computer: install cmux, then show its pairing code and words.
    /// Nil for a phone.
    public var setupLine: String? {
        switch self {
        case .macOrLinux:
            Self.pinnedInstall(then: "~/.cmux/bin/cmux server pair")
        case .windows:
            "irm https://cmux.com/tui/install-static.ps1 | iex; cmux server pair"
        case .phone:
            nil
        }
    }

    /// The sha256 of `web/public/tui/install-static.sh`, served unchanged forever at
    /// `https://cmux.com/tui/install-static/<sha256>.sh`. `cmux-tui/scripts/install-static-pin.py --write`
    /// sets it; its check (tests/test_tui_install_pin.py) fails when it differs from the script.
    public static let installStaticSHA256 = "f2cbb6f11bd4743973c3f492e8fe2d1c4700c114784394da909890adec3e57de"

    /// Installs cmux from the immutable script, run only after it matches ``installStaticSHA256``
    /// (cmuxterm-hq docs/design/linux-signed-packages.md, section 4): saved in a fresh `mktemp -d`
    /// directory (only this user can open it, so the checked file is the one run), checked with
    /// `sha256sum` on Linux or `shasum -a 256` on a Mac (which has no `sha256sum`), then `then` runs
    /// only when the install succeeded. Never `curl | sh` of a moving URL.
    public static func pinnedInstall(then next: String) -> String {
        let url = "https://cmux.com/tui/install-static/\(installStaticSHA256).sh"
        return "(d=\"$(mktemp -d)\" && curl -fsSL \(url) -o \"$d/install.sh\""
            + " && echo \"\(installStaticSHA256)  $d/install.sh\" | $(command -v sha256sum || echo shasum -a 256) -c"
            + " && sh \"$d/install.sh\"; s=$?; rm -rf \"$d\"; exit \"$s\") && \(next)"
    }
}
