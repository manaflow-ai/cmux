@testable import CmuxNextHome
import CoreGraphics
import Foundation

/// Fixtures shared by the Home tests.
enum HomeFixture {
    static let me = "user_local"
    static let agent = "agent_mux"
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static var geometry: TranscriptGeometry {
        TranscriptGeometry.make(width: 640, fontSize: 13, captionSize: 11, space: (2, 4, 6, 8, 10, 12))
    }

    static func strings() -> RowStrings {
        RowStrings(retracted: "Unsent", sending: "Sending", notDelivered: "Not delivered", read: "Read",
                   delivered: "Delivered", today: "Today", yesterday: "Yesterday", locale: Locale(identifier: "en_US_POSIX"))
    }

    static func context(measurer: Measurer = Measurer(), readThrough: Int? = nil, typing: Bool = false,
                        geometry: TranscriptGeometry = geometry) -> RowContext {
        RowContext(meID: me, geometry: geometry, now: base.addingTimeInterval(86_400), readThrough: readThrough,
                   typing: typing, strings: strings(), measurer: measurer)
    }

    /// Confirmed messages `seqs`, alternating authors in pairs, 30 s apart, a 20 min gap every 25.
    static func messages(_ seqs: ClosedRange<Int>) -> [HomeMessage] {
        seqs.map { seq in
            let author = (seq / 2) % 2 == 0 ? me : agent
            let gaps = Double(seq / 25) * 1200
            return HomeMessage(id: "msg_\(seq)", seq: seq, clientMsgID: "c\(seq)", authorID: author,
                               parts: [.text(String(repeating: "word ", count: 1 + seq % 17))],
                               createdAt: base.addingTimeInterval(Double(seq) * 30 + gaps),
                               delivery: author == me ? .sent : .none)
        }
    }

    static func window(_ seqs: ClosedRange<Int>, newest: Int? = nil, oldest: Int = 1) -> TranscriptWindow {
        var window = TranscriptWindow()
        _ = window.replace(messages(seqs), pending: [], newest: newest ?? seqs.upperBound, oldest: oldest)
        return window
    }

    static func pending(_ id: String, at offset: Double) -> HomeMessage {
        HomeMessage.pending(clientMsgID: id, authorID: me, parts: [.text("pending \(id)")],
                            createdAt: base.addingTimeInterval(offset))
    }
}

extension TranscriptLayout {
    /// Rows and tops as comparable values.
    var snapshot: [String] {
        zip(rows, tops).map { "\($0.key)@\($1)h\($0.height)x\($0.x)" }
    }
}
