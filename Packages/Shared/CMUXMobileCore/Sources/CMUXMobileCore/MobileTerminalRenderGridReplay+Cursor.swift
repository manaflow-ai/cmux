import Foundation

extension MobileTerminalRenderGridReplay {
    func appendCursorRestore(_ bytes: inout Data) {
        let defaultStyle = styleMapByID(frame.styles)[0] ?? .default
        bytes.append(sgrBytes(for: defaultStyle))
        guard let cursor = frame.cursor else {
            bytes.append(Data("\u{1B}[?25h".utf8))
            return
        }
        appendCursorRestore(cursor, to: &bytes)
    }

    func appendCursorRestore(
        _ cursor: MobileTerminalRenderGridFrame.Cursor,
        to bytes: inout Data
    ) {
        bytes.append(cursorStyleBytes(for: cursor))
        let preservesReconstructedActiveRow = switch cursor.location {
        case .aboveViewport, .belowViewport: true
        case .viewport: false
        case nil:
            // Older producers conflated an outside-viewport cursor with a
            // hidden cursor. Retain their behavior until both sides carry the
            // explicit location metadata.
            !cursor.visible
                && frame.activeScreen == .primary
                && frame.scrollForwardRows + frame.primaryActiveRows > 0
        }
        let restoredRow = cursor.activeRow ?? (preservesReconstructedActiveRow ? nil : cursor.row)
        let position = if let restoredRow {
            "\u{1B}[\(restoredRow + 1);\(cursor.column + 1)H"
        } else {
            "\u{1B}[\(cursor.column + 1)G"
        }
        bytes.append(Data("\u{1B}[?\(cursor.visible ? "25h" : "25l")\(position)".utf8))
    }

    func cursorStyleBytes(for cursor: MobileTerminalRenderGridFrame.Cursor) -> Data {
        let parameter: Int
        switch cursor.style {
        case .block, .blockHollow:
            parameter = cursor.blinking ? 1 : 2
        case .underline:
            parameter = cursor.blinking ? 3 : 4
        case .bar:
            parameter = cursor.blinking ? 5 : 6
        }
        return Data("\u{1B}[\(parameter) q".utf8)
    }
}
