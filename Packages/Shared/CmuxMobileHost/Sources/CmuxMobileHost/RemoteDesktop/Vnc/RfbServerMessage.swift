/// A server-to-client RFB message this client acts on.
public enum RfbServerMessage: Hashable, Sendable {
    case update([RfbRect])
    /// ServerCutText (Latin-1 on the wire).
    case cutText(String)
    case bell
    /// SetColourMapEntries (ignored: this client uses true colour).
    case colourMap
}
