import Testing
@testable import CMUXMobileCore

@Suite struct MobileWorkspaceMetadataLimitsTests {
    @Test func descriptionLimitCapsByUTF8BytesWithoutSplittingCharacters() {
        let value = String(repeating: "🧪", count: 2_000)

        let bounded = MobileWorkspaceMetadataLimits.normalizedCustomDescription(value)

        #expect(bounded?.utf8.count == MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes)
        #expect(bounded?.allSatisfy { $0 == "🧪" } == true)
    }

    @Test func descriptionLimitNormalizesLineEndingsAndTreatsBlankAsNil() {
        #expect(
            MobileWorkspaceMetadataLimits.normalizedCustomDescription("  release\r\ncheck  ")
                == "  release\ncheck  "
        )
        #expect(MobileWorkspaceMetadataLimits.normalizedCustomDescription(" \n ") == nil)
    }

    @Test func descriptionProjectionReportsWhenValueWasTruncated() {
        let projected = MobileWorkspaceMetadataLimits.projectedCustomDescription(
            String(repeating: "🧪", count: 2_000)
        )

        #expect(projected.value?.utf8.count == MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes)
        #expect(projected.isTruncated)
    }

    @Test func descriptionProjectionFindsLateNonWhitespaceWithoutReturningUnboundedText() {
        let prefix = String(
            repeating: " ",
            count: MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes + 10
        )

        let projected = MobileWorkspaceMetadataLimits.projectedCustomDescription(prefix + "tail")

        #expect(projected.value == String(
            repeating: " ",
            count: MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes
        ))
        #expect(projected.isTruncated)
    }

    @Test func descriptionProjectionTreatsHugeBlankInputAsNil() {
        let projected = MobileWorkspaceMetadataLimits.projectedCustomDescription(
            String(repeating: "\r\n", count: MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes)
        )

        #expect(projected.value == nil)
        #expect(!projected.isTruncated)
    }
}
