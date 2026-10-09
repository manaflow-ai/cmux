import Foundation
import Testing
@testable import CmuxMobileWire

@Suite struct FamilyFixtureTests {
    static let files: [String] = (try? Fixtures().familyFiles()) ?? []

    @Test func everyFamilyHasAFixtureFile() {
        #expect(Set(Self.files) == Set(MobileCatalog.v1.families.map { "\($0.name).json" }))
    }

    @Test(arguments: files)
    func fixturesRoundTripAndNameTheirMessage(file: String) throws {
        let fixtures = Fixtures()
        let doc = try fixtures.json("fixtures/\(file)")
        let family = try #require(doc["family"]?.stringValue)
        for c in try #require(doc["cases"]?.arrayValue) {
            let frame = try #require(c["frame"])
            let decoded = try MobileJSON(value: frame)
            #expect(try decoded.jsonValue == frame, "\(file): \(frame)")
            guard let name = c["message"]?.stringValue else { continue }
            let message = try #require(MobileCatalog.v1.message(named: name), "\(name) not in catalog")
            #expect(MobileCatalog.v1.family(ofMessage: name)?.name == family)
            guard (c["phase"]?.stringValue ?? "request") == "request" else { continue }
            switch (message.kind, decoded) {
            case (.message, .message(let m)):
                #expect(m.name == name)
            case (.op, .frame(let f)):
                #expect(f.type == .op && f.messageName == name)
            case (.read, .frame(let f)):
                #expect(f.type == .read && f.messageName == name)
            case (.owner, .frame(let f)):
                #expect(f.type == .event && f.messageName == name)
            case (.signal, .frame(let f)):
                #expect(f.type == .signal && f.messageName == name)
            case (.channel, .frame(.channelOpen(let open))):
                #expect(open.kind.rawValue == name && open.channelClass == message.channelClass)
            default:
                Issue.record("\(file): \(name) (\(message.kind)) decoded as \(decoded)")
            }
        }
    }
}
