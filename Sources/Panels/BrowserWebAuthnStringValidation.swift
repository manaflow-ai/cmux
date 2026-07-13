extension Optional where Wrapped == String {
    func validateWebAuthnString(maxUTF8Bytes: Int) throws {
        guard let self else { return }
        guard self.utf8.count <= maxUTF8Bytes else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
    }
}
