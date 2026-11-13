@testable import CmuxNextCloud
import Foundation
import Testing

/// CloudCarrierDial builds exactly the argv of cmux-tui/spec/fixtures/carrier-child-argv.json, which
/// cmux-tui's carrier `argv_contract_tests` runs through the real carrier CLI parser. The app's other
/// carrier tests spawn shell stand-ins that accept any argv; this ties the argv to the bundled CLI.
@Suite struct CloudCarrierArgvContractTests {
    private struct Fixture: Decodable {
        struct Child: Decodable {
            struct Builder: Decodable {
                let builder: String
                let machine: String
                let service: String
                let socket: String?
            }
            let name: String
            let swift: Builder
            let argv: [String]
        }
        let children: [Child]
    }

    private static func fixture() throws -> Fixture {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/fixtures/carrier-child-argv.json"))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    @Test func everyCarrierChildArgvIsTheOneTheRealParserChecks() throws {
        let children = try Self.fixture().children
        #expect(Set(children.map(\.swift.builder)) == ["arguments", "serveArguments"], "a carrier child the fixture does not cover")
        for child in children {
            let service = try #require(CloudCarrierDial.Service(rawValue: child.swift.service), "\(child.name)")
            let dial = try #require(CloudCarrierDial(machine: child.swift.machine, service: service), "\(child.name)")
            switch child.swift.builder {
            case "arguments":
                #expect(dial.arguments == child.argv, "\(child.name)")
            case "serveArguments":
                let socket = try #require(child.swift.socket, "\(child.name)")
                #expect(dial.serveArguments(socket: socket) == child.argv, "\(child.name)")
            default:
                Issue.record("\(child.name): CloudCarrierDial has no builder \(child.swift.builder)")
            }
        }
    }
}
