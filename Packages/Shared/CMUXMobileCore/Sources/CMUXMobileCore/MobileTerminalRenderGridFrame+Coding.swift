extension MobileTerminalRenderGridFrame {
    enum CodingKeys: String, CodingKey {
        case format
        case surfaceID = "surface_id"
        case stateSeq = "state_seq"
        case appliedInputSequence = "applied_input_sequence"
        case renderEpoch = "render_epoch"
        case renderRevision = "render_revision"
        case columns
        case rows
        case cursor
        case full
        case clearedRows = "cleared_rows"
        case styles
        case rowSpans = "row_spans"
        case activeScreen = "active_screen"
        case modes
        case terminalForeground = "terminal_foreground"
        case terminalBackground = "terminal_background"
        case terminalCursorColor = "terminal_cursor_color"
        case terminalTheme = "terminal_theme"
        case terminalConfigTheme = "terminal_config_theme"
        case terminalThemeRevision = "terminal_theme_revision"
        case scrollbackRows = "scrollback_rows"
        case scrollbackSpans = "scrollback_spans"
        case anchor
        case scrolledRows = "scrolled_rows"
        case historyRows = "history_rows"
        case deltaBaseHistoryRows = "delta_base_history_rows"
        case deltaBaseRenderRevision = "delta_base_render_revision"
        case rowSpaceRevision = "row_space_revision"
        case hostTiming = "host_timing"
    }
}

extension MobileTerminalRenderGridFrame {
    /// Writes only fields whose value differs from what ``init(from:)``
    /// assumes for a missing key, so the common delta (a few changed rows)
    /// does not repeat empty arrays and default enums on every frame. The
    /// output decodes identically on every consumer of this format, including
    /// builds that predate this encoder, because their decoder applies the
    /// same defaults.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(surfaceID, forKey: .surfaceID)
        try container.encode(stateSeq, forKey: .stateSeq)
        try container.encodeIfPresent(appliedInputSequence, forKey: .appliedInputSequence)
        if !renderEpoch.isEmpty {
            try container.encode(renderEpoch, forKey: .renderEpoch)
        }
        if renderRevision != 0 {
            try container.encode(renderRevision, forKey: .renderRevision)
        }
        try container.encode(columns, forKey: .columns)
        try container.encode(rows, forKey: .rows)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        if !full {
            try container.encode(full, forKey: .full)
        }
        if !clearedRows.isEmpty {
            try container.encode(clearedRows, forKey: .clearedRows)
        }
        if styles != [.default] {
            try container.encode(styles, forKey: .styles)
        }
        try container.encode(rowSpans, forKey: .rowSpans)
        if activeScreen != .primary {
            try container.encode(activeScreen, forKey: .activeScreen)
        }
        if !modes.isEmpty {
            try container.encode(modes, forKey: .modes)
        }
        try container.encodeIfPresent(terminalForeground, forKey: .terminalForeground)
        try container.encodeIfPresent(terminalBackground, forKey: .terminalBackground)
        try container.encodeIfPresent(terminalCursorColor, forKey: .terminalCursorColor)
        try container.encodeIfPresent(terminalTheme, forKey: .terminalTheme)
        try container.encodeIfPresent(terminalConfigTheme, forKey: .terminalConfigTheme)
        try container.encodeIfPresent(terminalThemeRevision, forKey: .terminalThemeRevision)
        if scrollbackRows != 0 {
            try container.encode(scrollbackRows, forKey: .scrollbackRows)
        }
        if !scrollbackSpans.isEmpty {
            try container.encode(scrollbackSpans, forKey: .scrollbackSpans)
        }
        if anchor != .viewport {
            try container.encode(anchor, forKey: .anchor)
        }
        if scrolledRows != 0 {
            try container.encode(scrolledRows, forKey: .scrolledRows)
        }
        try container.encodeIfPresent(historyRows, forKey: .historyRows)
        try container.encodeIfPresent(rowSpaceRevision, forKey: .rowSpaceRevision)
        try container.encodeIfPresent(deltaBaseHistoryRows, forKey: .deltaBaseHistoryRows)
        try container.encodeIfPresent(deltaBaseRenderRevision, forKey: .deltaBaseRenderRevision)
        try container.encodeIfPresent(hostTiming, forKey: .hostTiming)
    }
}
