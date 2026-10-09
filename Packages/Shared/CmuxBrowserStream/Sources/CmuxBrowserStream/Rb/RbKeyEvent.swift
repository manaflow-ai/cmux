/// A key event of `cmux.rb/1` (DOM `code` and `key`, as the page sees them).
public struct RbKeyEvent: Hashable, Sendable {
    public var down: Bool
    public var code: String
    public var key: String
    public var text: String
    public var unmodifiedText: String
    public var modifiers: RbModifiers
    public var isRepeat: Bool
    public var location: UInt8
    public var editCommands: [RbEditCommand]

    public init(down: Bool, code: String, key: String, text: String = "", unmodifiedText: String = "",
                modifiers: RbModifiers = [], isRepeat: Bool = false, location: UInt8 = 0, editCommands: [RbEditCommand] = []) {
        self.down = down
        self.code = code
        self.key = key
        self.text = text
        self.unmodifiedText = unmodifiedText
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.location = location
        self.editCommands = editCommands
    }
}
