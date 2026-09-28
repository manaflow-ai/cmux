/// What one native clipboard read may take from the pasteboard.
public enum RuntimeClipboardReadContent: Equatable, Sendable {
    /// Everything a paste can use: text, file paths and images, which cmux
    /// may save and upload for the pane.
    case pasteboard

    /// The pasteboard's plain-text flavor only. Files and images are never
    /// read, saved or uploaded.
    case plainText

    /// The content a read with this input admission may take.
    ///
    /// A reserved request comes from a native paste gesture: a key binding,
    /// the Paste menu item or a middle click. An unsequenced one was started
    /// by the terminal program, for example with OSC 52, so it gets plain
    /// text only.
    ///
    /// - Parameter admission: The request's input admission.
    public init(admission: RuntimeClipboardInputAdmission) {
        self = admission.reservesInput ? .pasteboard : .plainText
    }
}
