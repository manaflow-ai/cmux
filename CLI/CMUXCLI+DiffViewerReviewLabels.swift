import Foundation

extension CMUXCLI.DiffViewerLabels {
    /// Labels for the review-parity controls (viewed state, file filter,
    /// generated and large-diff collapse). Kept out of `cmux_open.swift`,
    /// which is over the file length budget; `localized()` merges them.
    static var reviewParityLabels: [String: String] {
        [
            "changedSinceViewed": CMUXDiffViewerLocalization.string("diffViewer.changedSinceViewed", defaultValue: "Changed since viewed"),
            "clearFileFilter": CMUXDiffViewerLocalization.string("diffViewer.clearFileFilter", defaultValue: "Clear filter"),
            "filesViewedProgress": CMUXDiffViewerLocalization.string("diffViewer.filesViewedProgress", defaultValue: "{viewed} of {total} files viewed"),
            "filterAddedFiles": CMUXDiffViewerLocalization.string("diffViewer.filterAddedFiles", defaultValue: "Added"),
            "filterDeletedFiles": CMUXDiffViewerLocalization.string("diffViewer.filterDeletedFiles", defaultValue: "Deleted"),
            "filterFiles": CMUXDiffViewerLocalization.string("diffViewer.filterFiles", defaultValue: "Filter files"),
            "filterModifiedFiles": CMUXDiffViewerLocalization.string("diffViewer.filterModifiedFiles", defaultValue: "Modified"),
            "filterRenamedFiles": CMUXDiffViewerLocalization.string("diffViewer.filterRenamedFiles", defaultValue: "Renamed"),
            "generatedFile": CMUXDiffViewerLocalization.string("diffViewer.generatedFile", defaultValue: "Generated file"),
            "hideViewedFiles": CMUXDiffViewerLocalization.string("diffViewer.hideViewedFiles", defaultValue: "Hide viewed files"),
            "largeDiff": CMUXDiffViewerLocalization.string("diffViewer.largeDiff", defaultValue: "Large diff"),
            "loadDiff": CMUXDiffViewerLocalization.string("diffViewer.loadDiff", defaultValue: "Load diff"),
            "markNotViewed": CMUXDiffViewerLocalization.string("diffViewer.markNotViewed", defaultValue: "Mark as not viewed"),
            "markViewed": CMUXDiffViewerLocalization.string("diffViewer.markViewed", defaultValue: "Mark as viewed"),
            "noFilesMatchFilter": CMUXDiffViewerLocalization.string("diffViewer.noFilesMatchFilter", defaultValue: "No files match the filter."),
            "showViewedFiles": CMUXDiffViewerLocalization.string("diffViewer.showViewedFiles", defaultValue: "Show viewed files"),
            "viewed": CMUXDiffViewerLocalization.string("diffViewer.viewed", defaultValue: "Viewed"),
        ]
    }
}
