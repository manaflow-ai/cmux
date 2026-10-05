import CmuxNextActions
import Testing

/// The certificate warning page's Proceed and Go Back are actions: in the
/// palette and bindable to a shortcut, for a focused browser page. They
/// have no CLI verb (and so no MCP tool): an agent never proceeds past a
/// certificate warning by name; `cmux action run` still reaches them.
@MainActor
struct CertificateWarningActionTests {
    @Test func theWarningPageControlsAreActions() throws {
        for id in ["browser.certificateWarning.proceed", "browser.certificateWarning.goBack"] as [ActionID] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id)")
            #expect(descriptor.isPaletteVisible, "\(id)")
            #expect(descriptor.surfaces.contains(.keyboard), "\(id)")
            #expect(descriptor.requires.contains(.browserFocused), "\(id)")
            #expect(!descriptor.cli, "\(id) has no CLI verb")
            #expect(descriptor.surfacePlan.mcp?.isOffered != true, "\(id) is no MCP tool")
        }
    }
}
