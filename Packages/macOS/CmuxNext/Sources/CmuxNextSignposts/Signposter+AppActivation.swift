import CmuxNextCompat

// The `switch.app_activation` begin with its numbers: one `OSSignposter` interval, the MetricKit mirror's and one
// trace ring async slice (AB/AE) while the `switch` category is on. The message fields are formatted by the log system
// only when something reads it.
extension Signposter {
    /// The begin `arg0` bit set when the turn had the app's become or resign active notice.
    static let appActivationBit: UInt64 = 1 << 8

    /// Begins a ``SignpostName/switchAppActivation``: a window's key tracker flipped the window's look (its inactive
    /// wash on or off) for a turn of key or activation notices (`notice=<name> app=<0|1> age_ms=<age, 2 decimals>`).
    /// The ring's AB holds the notice's code in bits 0-7, ``appActivationBit`` and the notice's age in us in the top
    /// 24 bits of `arg0`. End it with ``end(_:_:_:)`` at the ``CommitBoundary`` after the flip.
    ///
    /// - Parameters:
    ///   - noticeCode: The turn's first notice, 1-6 (the table in ``SignpostName/switchAppActivation``).
    ///   - noticeName: That notice's name.
    ///   - appActivation: The turn had the app's become or resign active notice (a Cmd-Tab, not a focus move in the
    ///     app).
    ///   - noticeAgeMilliseconds: The first notice's age at the flip.
    /// - Returns: The state to pass to ``end(_:_:_:)``.
    public func beginAppActivation(noticeCode: UInt8, noticeName: String, appActivation: Bool,
                                   noticeAgeMilliseconds: Double) -> SignpostInterval {
        let arg0 = UInt64(noticeCode) | (appActivation ? Self.appActivationBit : 0)
            | Self.inputAgeBits(milliseconds: noticeAgeMilliseconds)
        let app = appActivation ? 1 : 0
        return openInterval(.switchAppActivation, arg0: arg0) {
            signposter.beginInterval(SignpostName.switchAppActivation.staticName, id: $0,
                                     "notice=\(noticeName, privacy: .public) app=\(app, privacy: .public) age_ms=\(noticeAgeMilliseconds, format: .fixed(precision: 2), privacy: .public)")
        }
    }
}
