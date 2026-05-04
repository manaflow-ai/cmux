import CMUXCore
import XCTest

final class SocketMethodRegistryTests: XCTestCase {
    func testProductionMethodRegistryContainsCoreAndBrowserMethods() throws {
        XCTAssertTrue(SocketMethodRegistry.contains("system.ping", includeDebug: false))
        XCTAssertTrue(SocketMethodRegistry.contains("workspace.list", includeDebug: false))
        XCTAssertTrue(SocketMethodRegistry.contains("browser.dialog.accept", includeDebug: false))
        XCTAssertTrue(SocketMethodRegistry.contains("markdown.open", includeDebug: false))
    }

    func testDebugMethodsAreExcludedWhenRequested() throws {
        XCTAssertTrue(SocketMethodRegistry.contains("debug.command_palette.toggle"))
        XCTAssertFalse(SocketMethodRegistry.contains("debug.command_palette.toggle", includeDebug: false))
    }

    func testMethodListsDoNotContainDuplicates() throws {
        XCTAssertEqual(
            Set(SocketMethodRegistry.productionMethodNames).count,
            SocketMethodRegistry.productionMethodNames.count
        )
        XCTAssertEqual(
            Set(SocketMethodRegistry.debugMethodNames).count,
            SocketMethodRegistry.debugMethodNames.count
        )
    }

    func testDescriptorsExposeDomainAndFocusIntent() throws {
        XCTAssertEqual(SocketMethodRegistry.descriptor(for: "system.ping")?.domain, .system)
        XCTAssertEqual(SocketMethodRegistry.descriptor(for: "browser.focus")?.domain, .browser)
        XCTAssertEqual(SocketMethodRegistry.descriptor(for: "workspace.select")?.domain, .workspace)
        XCTAssertTrue(SocketMethodRegistry.descriptor(for: "workspace.select")?.isFocusIntent == true)
        XCTAssertTrue(SocketMethodRegistry.descriptor(for: "surface.focus")?.isFocusIntent == true)
        XCTAssertFalse(SocketMethodRegistry.descriptor(for: "workspace.list")?.isFocusIntent == true)
    }

    func testRegistryRejectsUnknownOrPaddedMethods() throws {
        XCTAssertNil(SocketMethodRegistry.descriptor(for: "missing.method"))
        XCTAssertNil(SocketMethodRegistry.descriptor(for: " system.ping"))
        XCTAssertNil(SocketMethodRegistry.descriptor(for: "system.ping "))
    }
}
