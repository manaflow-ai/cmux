/// Universal text predicates shared by AppKit edit ownership and terminal key
/// planning.
enum TerminalTextInputText {
    static func isSingleC0(_ text: String?) -> Bool {
        guard let scalar = singleScalar(in: text) else { return false }
        return scalar.value < 0x20
    }

    static func isSingleC0OrDelete(_ text: String?) -> Bool {
        guard let scalar = singleScalar(in: text) else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func singleScalar(
        in text: String?
    ) -> Unicode.Scalar? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return nil
        }
        return scalar
    }
}
