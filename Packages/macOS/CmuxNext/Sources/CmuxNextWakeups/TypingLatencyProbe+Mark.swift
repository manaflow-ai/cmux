import CmuxNextSignposts

extension TypingLatencyProbe {
    /// A hop of a sampled press: its CSV column, its `key.flow` hop and the hop that must run before it.
    public enum Mark: Int, CaseIterable, Sendable {
        case dispatchStart, dispatchEnd, ioWrite, socketSubmit, outputDecoded, outputReceived, outputParsed, contents, commit

        /// The `key.flow` hop this mark records.
        var hop: KeyFlowHop {
            switch self {
            case .dispatchStart: .appKeyDispatch
            case .dispatchEnd: .appKeyDispatched
            case .ioWrite: .appIOWrite
            case .socketSubmit: .appSend
            case .outputDecoded: .appOutputDecoded
            case .outputReceived: .appOutputReceived
            case .outputParsed: .appOutputParsed
            case .contents: .appFrameContents
            case .commit: .appKeyCommit
            }
        }

        var columnName: String {
            switch self {
            case .dispatchStart: "dispatch_start_ms"
            case .dispatchEnd: "dispatch_end_ms"
            case .ioWrite: "io_write_ms"
            case .socketSubmit: "socket_submit_ms"
            case .outputDecoded: "output_decoded_ms"
            case .outputReceived: "output_received_ms"
            case .outputParsed: "output_parsed_ms"
            case .contents: "contents_ms"
            case .commit: "commit_ms"
            }
        }

        /// The hop that must have run first, so output from an earlier key
        /// is not taken for this key's echo.
        var after: Mark? {
            switch self {
            case .dispatchStart, .dispatchEnd, .ioWrite: nil
            case .socketSubmit: .ioWrite
            case .outputDecoded: .socketSubmit
            case .outputReceived: .outputDecoded
            case .outputParsed: .outputReceived
            case .contents: .outputParsed
            case .commit: .dispatchEnd
            }
        }
    }
}
