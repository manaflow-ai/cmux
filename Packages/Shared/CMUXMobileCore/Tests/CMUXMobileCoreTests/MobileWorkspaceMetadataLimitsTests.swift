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

    @Test func descriptionProjectionStopsAtBudgetBeforeLateNonWhitespace() {
        let prefix = String(
            repeating: " ",
            count: MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes + 10
        )

        let projected = MobileWorkspaceMetadataLimits.projectedCustomDescription(prefix + "tail")

        #expect(projected.value == nil)
        #expect(projected.isTruncated)
    }

    @Test func descriptionProjectionTreatsHugeBlankInputAsTruncatedNil() {
        let projected = MobileWorkspaceMetadataLimits.projectedCustomDescription(
            String(repeating: "\r\n", count: MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes + 1)
        )

        #expect(projected.value == nil)
        #expect(projected.isTruncated)
    }

    @Test func descriptionProjectionConsumesAggregateJSONEscapedBudget() {
        var budget = MobileWorkspaceMetadataLimits.jsonEscapedUTF8ByteCount("ok")

        let first = MobileWorkspaceMetadataLimits.projection(
            MobileWorkspaceDescriptionProjection(value: "ok", isTruncated: false),
            constrainedToJSONEscapedUTF8Budget: &budget
        )
        let second = MobileWorkspaceMetadataLimits.projection(
            MobileWorkspaceDescriptionProjection(value: "later", isTruncated: false),
            constrainedToJSONEscapedUTF8Budget: &budget
        )

        #expect(first.value == "ok")
        #expect(!first.isTruncated)
        #expect(second.value == nil)
        #expect(second.isTruncated)
        #expect(budget == 0)
    }

    @Test func descriptionProjectionTruncatesByAggregateJSONEscapedBudget() {
        let value = "a\"b"
        var budget = MobileWorkspaceMetadataLimits.jsonEscapedUTF8ByteCount("a\"")

        let projected = MobileWorkspaceMetadataLimits.projection(
            MobileWorkspaceDescriptionProjection(value: value, isTruncated: false),
            constrainedToJSONEscapedUTF8Budget: &budget
        )

        #expect(projected.value == "a\"")
        #expect(projected.isTruncated)
        #expect(budget == 0)
        #expect(
            MobileWorkspaceMetadataLimits.jsonEscapedUTF8ByteCount(projected.value ?? "")
                <= MobileWorkspaceMetadataLimits.jsonEscapedUTF8ByteCount("a\"")
        )
    }
}
