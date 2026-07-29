/// Value-semantic classification shared by AppKit edit ownership and terminal
/// key planning.
struct TerminalTextInputClassification: Sendable {
    func isSingleC0(_ text: String?) -> Bool {
        guard let scalar = singleScalar(in: text) else { return false }
        return scalar.value < 0x20
    }

    func isSingleC0OrDelete(_ text: String?) -> Bool {
        guard let scalar = singleScalar(in: text) else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    private func singleScalar(
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
