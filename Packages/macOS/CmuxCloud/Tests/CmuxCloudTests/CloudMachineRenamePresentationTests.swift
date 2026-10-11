import Testing

import CmuxCloud

@Suite("Cloud machine rename presentation")
struct CloudMachineRenamePresentationTests {
    private let presentation = CloudMachineRenamePresentation()

    @Test("uses the explicit display label")
    func usesDisplayLabel() {
        let machine = Self.machine(label: "Build machine", slug: "sleepy-teal-otter")

        #expect(presentation.promptName(for: machine, fallbackName: "Cloud machine") == "Build machine")
    }

    @Test("uses the generated slug when no display label exists")
    func usesGeneratedSlug() {
        let machine = Self.machine(label: nil, slug: "sleepy-teal-otter")

        #expect(presentation.promptName(for: machine, fallbackName: "Cloud machine") == "sleepy-teal-otter")
    }

    @Test("uses the caller's short fallback when both names are missing")
    func usesFallback() {
        let machine = Self.machine(label: nil, slug: nil)

        #expect(presentation.promptName(for: machine, fallbackName: "Cloud machine") == "Cloud machine")
        #expect(presentation.promptName(for: machine, fallbackName: "Cloud machine") != machine.id)
    }

    @Test("ignores whitespace-only names")
    func ignoresWhitespace() {
        let machine = Self.machine(label: "   ", slug: "\n")

        #expect(presentation.promptName(for: machine, fallbackName: "Cloud machine") == "Cloud machine")
    }

    @Test("uses the generated slug after a whitespace-only label")
    func usesSlugAfterWhitespaceLabel() {
        let machine = Self.machine(label: "  ", slug: "sleepy-teal-otter")

        #expect(presentation.promptName(for: machine, fallbackName: "Cloud machine") == "sleepy-teal-otter")
    }

    @Test("projects an in-flight label onto only the renamed machine")
    func appliesOptimisticLabel() {
        let first = Self.machine(label: nil, slug: "first-machine")
        let second = MachineSnapshot(
            id: "vm-second",
            provider: first.provider,
            image: first.image,
            isDesktop: first.isDesktop,
            activity: first.activity,
            label: "Second",
            slug: "second-machine"
        )

        let updated = MachineSnapshotBuilder.applyingLabel(
            to: [first, second], machineID: first.id, label: "Renamed"
        )

        #expect(updated.map(\.label) == ["Renamed", "Second"])
    }

    private static func machine(label: String?, slug: String?) -> MachineSnapshot {
        MachineSnapshot(
            id: "vm-1f7ddfedaa024f559b-d0b959327fe3f6",
            provider: "freestyle",
            image: "cmux-devbox",
            isDesktop: false,
            activity: .ready,
            label: label,
            slug: slug
        )
    }
}
