import AppKit

public enum OwlKeyEditCommandMapper {
    public static func editCommands(keyDown: Bool, keyCode: UInt32, modifiers: UInt32) -> [String] {
        guard keyDown else {
            return []
        }

        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)

        if command, !option, !control {
            return commandEditCommand(keyCode: keyCode, shift: shift)
        }
        if option, !command, !control {
            return optionEditCommand(keyCode: keyCode, shift: shift)
        }
        if control, !command, !option {
            return controlEditCommand(keyCode: keyCode, shift: shift)
        }
        if shift, !command, !option, !control {
            return shiftEditCommand(keyCode: keyCode)
        }
        return []
    }

    private static func commandEditCommand(keyCode: UInt32, shift: Bool) -> [String] {
        switch keyCode {
        case 8:
            return ["DeleteToBeginningOfLine"]
        case 37:
            return [shift ? "MoveToBeginningOfLineAndModifySelection" : "MoveToBeginningOfLine"]
        case 38:
            return [shift ? "MoveToBeginningOfDocumentAndModifySelection" : "MoveToBeginningOfDocument"]
        case 39:
            return [shift ? "MoveToEndOfLineAndModifySelection" : "MoveToEndOfLine"]
        case 40:
            return [shift ? "MoveToEndOfDocumentAndModifySelection" : "MoveToEndOfDocument"]
        case 46:
            return ["DeleteToEndOfLine"]
        case 65:
            return ["SelectAll"]
        case 67:
            return ["Copy"]
        case 86:
            return ["Paste"]
        case 88:
            return ["Cut"]
        case 90:
            return [shift ? "Redo" : "Undo"]
        default:
            return []
        }
    }

    private static func optionEditCommand(keyCode: UInt32, shift: Bool) -> [String] {
        switch keyCode {
        case 8:
            return ["DeleteWordBackward"]
        case 37:
            return [shift ? "MoveWordBackwardAndModifySelection" : "MoveWordBackward"]
        case 38:
            return [shift ? "MoveToBeginningOfParagraphAndModifySelection" : "MoveToBeginningOfParagraph"]
        case 39:
            return [shift ? "MoveWordForwardAndModifySelection" : "MoveWordForward"]
        case 40:
            return [shift ? "MoveToEndOfParagraphAndModifySelection" : "MoveToEndOfParagraph"]
        case 46:
            return ["DeleteWordForward"]
        default:
            return []
        }
    }

    private static func controlEditCommand(keyCode: UInt32, shift: Bool) -> [String] {
        switch keyCode {
        case 65:
            return [shift ? "MoveToBeginningOfParagraphAndModifySelection" : "MoveToBeginningOfParagraph"]
        case 66:
            return [shift ? "MoveBackwardAndModifySelection" : "MoveBackward"]
        case 68:
            return ["DeleteForward"]
        case 69:
            return [shift ? "MoveToEndOfParagraphAndModifySelection" : "MoveToEndOfParagraph"]
        case 70:
            return [shift ? "MoveForwardAndModifySelection" : "MoveForward"]
        case 72:
            return ["DeleteBackward"]
        case 75:
            return ["DeleteToEndOfParagraph"]
        case 78:
            return [shift ? "MoveDownAndModifySelection" : "MoveDown"]
        case 80:
            return [shift ? "MoveUpAndModifySelection" : "MoveUp"]
        case 84:
            return ["Transpose"]
        default:
            return []
        }
    }

    private static func shiftEditCommand(keyCode: UInt32) -> [String] {
        switch keyCode {
        case 33:
            return ["MovePageUpAndModifySelection"]
        case 34:
            return ["MovePageDownAndModifySelection"]
        case 35:
            return ["MoveToEndOfLineAndModifySelection"]
        case 36:
            return ["MoveToBeginningOfLineAndModifySelection"]
        case 37:
            return ["MoveLeftAndModifySelection"]
        case 38:
            return ["MoveUpAndModifySelection"]
        case 39:
            return ["MoveRightAndModifySelection"]
        case 40:
            return ["MoveDownAndModifySelection"]
        default:
            return []
        }
    }
}
