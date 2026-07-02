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

    func appendSavedModeBankReset(to bytes: inout Data) {
        // XTSAVE (CSI ? Pm s) overwrites Ghostty's saved-mode slots with the
        // current values, which are all defaults right after the structural
        // reset and default baseline. RIS cleared the saved bank outright;
        // without this, a mode XTSAVE'd by a previous program on the reused
        // surface would survive the replay and a later XTRESTORE (CSI ? Pm r)
        // could resurrect it. The cursor modes ?12/?25 are forced to their
        // Ghostty defaults first so their saved slots are deterministic; the
        // paint sequence and the final cursor restore adjust the live values
        // afterwards without touching the bank. Ghostty caps CSI parameters
        // at 24 per sequence, so the bank is overwritten in two batches.
        // 2026 is deliberately absent: it is held on for the synchronized
        // replay and must not be saved in that state.
        bytes.append(Data("\u{1B}[?12l\u{1B}[?25h".utf8))
        bytes.append(Data("\u{1B}[?1;4;5;6;7;8;9;12;25;40;45;47;66;67;69;1000;1002;1003s".utf8))
        bytes.append(Data(
            "\u{1B}[?1004;1005;1006;1007;1015;1016;1035;1036;1039;1045;1047;1049;2004;2027;2031;2048s".utf8
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
