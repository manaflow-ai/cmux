/// Where a TextBox submit goes: a paste of the text, then the Return key.
@MainActor
package protocol TextBoxSink: AnyObject {
    /// Sends `text` as a paste (bracketed when the program asked for it).
    func paste(_ text: String)
    /// Sends the Return key.
    func pressReturn()
}
