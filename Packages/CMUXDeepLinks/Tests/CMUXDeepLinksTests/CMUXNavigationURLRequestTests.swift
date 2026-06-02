import CMUXDeepLinks
import Foundation
import XCTest

final class CMUXNavigationURLRequestTests: XCTestCase {
    private let supportedScheme = "cmux-test"
    private let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let paneId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let surfaceId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testParsesWorkspacePaneSurfaceAndTabLinks() throws {
        let workspaceURL = try XCTUnwrap(URL(string: "\(supportedScheme)://workspace/\(workspaceId.uuidString)"))
        let paneURL = try XCTUnwrap(URL(string: "\(supportedScheme)://workspace/\(workspaceId.uuidString)/pane/\(paneId.uuidString)"))
        let surfaceURL = try XCTUnwrap(URL(string: "\(supportedScheme)://workspace/\(workspaceId.uuidString)/surface/\(surfaceId.uuidString)"))
        let panelAliasURL = try XCTUnwrap(URL(string: "\(supportedScheme)://workspace/\(workspaceId.uuidString)/panel/\(surfaceId.uuidString)"))
        let tabAliasURL = try XCTUnwrap(URL(string: "\(supportedScheme)://workspace/\(workspaceId.uuidString)/tab/\(surfaceId.uuidString)"))

        XCTAssertEqual(try parsedTarget(workspaceURL), .workspace(workspaceId))
        XCTAssertEqual(try parsedTarget(paneURL), .pane(workspaceId: workspaceId, paneId: paneId))
        XCTAssertEqual(try parsedTarget(surfaceURL), .surface(workspaceId: workspaceId, surfaceId: surfaceId))
        XCTAssertEqual(try parsedTarget(panelAliasURL), .surface(workspaceId: workspaceId, surfaceId: surfaceId))
        XCTAssertEqual(try parsedTarget(tabAliasURL), .surface(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    func testGeneratedLinksRoundTrip() throws {
        let workspaceURL = try XCTUnwrap(URL(string: CMUXNavigationURLRequest.workspaceLink(workspaceId: workspaceId, scheme: supportedScheme)))
        let paneURL = try XCTUnwrap(URL(string: CMUXNavigationURLRequest.paneLink(workspaceId: workspaceId, paneId: paneId, scheme: supportedScheme)))
        let surfaceURL = try XCTUnwrap(URL(string: CMUXNavigationURLRequest.surfaceLink(workspaceId: workspaceId, surfaceId: surfaceId, scheme: supportedScheme)))
        let tabURL = try XCTUnwrap(URL(string: CMUXNavigationURLRequest.tabLink(workspaceId: workspaceId, tabId: surfaceId, scheme: supportedScheme)))

        XCTAssertEqual(try parsedTarget(workspaceURL), .workspace(workspaceId))
        XCTAssertEqual(try parsedTarget(paneURL), .pane(workspaceId: workspaceId, paneId: paneId))
        XCTAssertEqual(try parsedTarget(surfaceURL), .surface(workspaceId: workspaceId, surfaceId: surfaceId))
        XCTAssertEqual(try parsedTarget(tabURL), .surface(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    func testIgnoresOtherCmuxRoutesAndInactiveSchemes() throws {
        let sshURL = try XCTUnwrap(URL(string: "\(supportedScheme)://ssh?host=dev.example.com"))
        let authURL = try XCTUnwrap(URL(string: "\(supportedScheme)://auth-callback?stack_refresh=abc"))
        let inactiveURL = try XCTUnwrap(URL(string: "cmux-other://workspace/\(workspaceId.uuidString)"))

        XCTAssertNil(try parsedOptional(sshURL))
        XCTAssertNil(try parsedOptional(authURL))
        XCTAssertNil(try parsedOptional(inactiveURL))
    }

    func testRejectsQueryFragmentAuthorityAndExtraPathComponents() throws {
        let cases = [
            "\(supportedScheme)://workspace/\(workspaceId.uuidString)?command=id",
            "\(supportedScheme)://workspace/\(workspaceId.uuidString)#fragment",
            "\(supportedScheme)://user@workspace/\(workspaceId.uuidString)",
            "\(supportedScheme)://workspace:123/\(workspaceId.uuidString)",
            "\(supportedScheme)://workspace/\(workspaceId.uuidString)/surface/\(surfaceId.uuidString)/run",
        ]

        for rawURL in cases {
            let url = try XCTUnwrap(URL(string: rawURL))
            switch CMUXNavigationURLRequest.parse(url, supportedSchemes: [supportedScheme]) {
            case .failure(.unsupportedURLShape):
                break
            default:
                XCTFail("Expected unsupported URL shape rejection for \(rawURL)")
            }
        }
    }

    func testRejectsNonUUIDIdentifiersAndRelativeRefs() throws {
        let cases = [
            ("\(supportedScheme)://workspace/workspace:1", "workspace"),
            ("\(supportedScheme)://workspace/\(workspaceId.uuidString)/pane/pane:1", "pane"),
            ("\(supportedScheme)://workspace/\(workspaceId.uuidString)/surface/surface:1", "surface"),
            ("\(supportedScheme)://workspace/\(workspaceId.uuidString)/tab/tab:1", "tab"),
        ]

        for (rawURL, component) in cases {
            let url = try XCTUnwrap(URL(string: rawURL))
            switch CMUXNavigationURLRequest.parse(url, supportedSchemes: [supportedScheme]) {
            case .failure(.invalidIdentifier(component)):
                break
            default:
                XCTFail("Expected invalid \(component) rejection for \(rawURL)")
            }
        }
    }

    private func parsedOptional(_ url: URL) throws -> CMUXNavigationURLRequest? {
        switch CMUXNavigationURLRequest.parse(url, supportedSchemes: [supportedScheme]) {
        case .success(let request):
            return request
        case .failure(let error):
            throw error
        }
    }

    private func parsedTarget(_ url: URL) throws -> CMUXNavigationURLRequest.Target {
        let request = try XCTUnwrap(parsedOptional(url))
        return request.target
    }
}
