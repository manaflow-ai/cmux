import Foundation
import Testing
@testable import CmuxNextIPC

/// `ResourceFieldUpdate`, a request's optional nullable field: absent keeps, `null`
/// clears, a value sets, both ways.
@Suite struct ResourceFieldUpdateTests {
    private struct Patch: Codable, Equatable {
        var title: ResourceFieldUpdate<String>

        enum CodingKeys: String, CodingKey {
            case title
        }

        init(title: ResourceFieldUpdate<String>) {
            self.title = title
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try ResourceFieldUpdate(from: container, forKey: .title)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try title.encode(into: &container, forKey: .title)
        }
    }

    private static func text(_ patch: Patch) throws -> String {
        String(decoding: try JSONEncoder().encode(patch), as: UTF8.self)
    }

    @Test func encodesNothingNullOrTheValue() throws {
        #expect(try Self.text(Patch(title: .unchanged)) == "{}")
        #expect(try Self.text(Patch(title: .clear)) == #"{"title":null}"#)
        #expect(try Self.text(Patch(title: .set("Build"))) == #"{"title":"Build"}"#)
    }

    @Test func decodesAbsentNullAndAValue() throws {
        func decode(_ json: String) throws -> Patch {
            try JSONDecoder().decode(Patch.self, from: Data(json.utf8))
        }
        #expect(try decode("{}").title == .unchanged)
        #expect(try decode(#"{"title":null}"#).title == .clear)
        #expect(try decode(#"{"title":"Build"}"#).title == .set("Build"))
        #expect(throws: DecodingError.self) { try decode(#"{"title":7}"#) }
    }
}
