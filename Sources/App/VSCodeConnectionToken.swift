/// Connection-token format helpers. VS Code Web compares the URL `tkn` query item
/// against this file's contents, so a stable, valid token keeps the server URL —
/// and the browser-side session/cookies keyed to it — consistent across launches.
enum VSCodeConnectionToken {
    private static let hexCharacters = Set("0123456789abcdefABCDEF")

    static func isValid(_ token: String) -> Bool {
        guard token.count == 32 else { return false }
        return token.allSatisfy { hexCharacters.contains($0) }
    }

    /// 128 bits of randomness rendered as 32 lowercase hex characters.
    static func generate() -> String {
        let hexDigits = Array("0123456789abcdef")
        var characters = [Character]()
        characters.reserveCapacity(32)
        for _ in 0..<16 {
            let byte = UInt8.random(in: UInt8.min...UInt8.max)
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(characters)
    }
}
