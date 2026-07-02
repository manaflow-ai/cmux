import Foundation

extension MobileTerminalRenderGridReplay {
    func appendStructuralScreenReset(to bytes: inout Data) {
        bytes.append(Data("\u{1B}[?47l\u{1B}[?1047l\u{1B}[?1049l".utf8))
    }

    func appendDefaultModeBaseline(to bytes: inout Data) {
        bytes.append(Data(
            (
                "\u{1B}[2l\u{1B}[4l\u{1B}[12h\u{1B}[20l"
                + "\u{1B}[?1l\u{1B}[?4l\u{1B}[?5l\u{1B}[?6l\u{1B}[?7h\u{1B}[?8l\u{1B}[?9l"
                + "\u{1B}[?40l\u{1B}[?45l\u{1B}[?66l\u{1B}>\u{1B}[?67l\u{1B}[?69l"
                + "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1004l"
                + "\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1007h\u{1B}[?1015l\u{1B}[?1016l"
                + "\u{1B}[?1035h\u{1B}[?1036h\u{1B}[?1039l\u{1B}[?1045l\u{1B}[?2004l"
                + "\u{1B}[?2027l\u{1B}[?2031l\u{1B}[?2048l"
            ).utf8
        ))
    }

    func appendPrePaintModeRestores(to bytes: inout Data) {
        for mode in frame.modes where !mode.ansi && mode.code == 2027 {
            bytes.append(Data("\u{1B}[?2027\(mode.on ? "h" : "l")".utf8))
        }
    }

    func isReplayExcludedMode(_ mode: MobileTerminalRenderGridFrame.ModeSetting) -> Bool {
        guard !mode.ansi else { return false }
        switch mode.code {
        // DECCOLM (?3) is geometry, not paint state: Ghostty implements reset
        // as a resize to 80 columns, while mobile render-grid delivery applies
        // the authoritative remote grid through its viewport policy.
        case 3, 12, 25, 47, 1047, 1048, 1049, 2026, 2031, 2048:
            return true
        default:
            return false
        }
    }
}
