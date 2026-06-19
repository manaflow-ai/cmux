import Testing
@testable import CmuxSettings

@Suite("BindableCommandDescriptor")
struct BindableCommandDescriptorTests {
    @Test func storesIdAndTitleAndIsIdentifiedById() {
        let descriptor = BindableCommandDescriptor(id: "palette.triggerFlash", title: "Trigger Flash")
        #expect(descriptor.id == "palette.triggerFlash")
        #expect(descriptor.title == "Trigger Flash")
    }

    @Test func equatableByValue() {
        let a = BindableCommandDescriptor(id: "x", title: "X")
        let b = BindableCommandDescriptor(id: "x", title: "X")
        #expect(a == b)
    }
}

@Suite("NoopBindableCommandCatalog")
@MainActor
struct NoopBindableCommandCatalogTests {
    @Test func returnsEmptyList() async {
        let provider: any BindableCommandCatalogProviding = NoopBindableCommandCatalog()
        let result = await provider.bindableCommands()
        #expect(result.isEmpty)
    }
}
