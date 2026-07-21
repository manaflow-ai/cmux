#if os(iOS)
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TaskComposerDirectoryPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var searchResponse: MobileTaskDirectorySearchResponse?
    @State private var isSearchingMac = false
    @State private var searchFailure: MobileTaskDirectorySearchFailure?
    @State private var searchRetryGeneration = 0

    @State private var browseState: TaskComposerDirectoryBrowseState

    private let candidates: [MobileTaskDirectoryCandidate]
    private let selectedPathID: MobileTaskDirectoryPathID
    private let select: (String) -> Void
    private let searchMac: (
        String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>
    private let listMac: (
        _ path: String,
        _ offset: Int
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>

    init(
        candidates: [MobileTaskDirectoryCandidate],
        selectedPath: String,
        select: @escaping (String) -> Void,
        searchMac: @escaping (
            String
        ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>,
        listMac: @escaping (
            _ path: String,
            _ offset: Int
        ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>
    ) {
        self.candidates = candidates
        selectedPathID = MobileTaskDirectoryPathID(path: selectedPath)
        self.select = select
        self.searchMac = searchMac
        self.listMac = listMac
        _browseState = State(
            initialValue: TaskComposerDirectoryBrowseState(initialPath: selectedPath)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isSearchMode {
                        searchContent
                    } else {
                        browseContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.search",
                        defaultValue: "Search folders"
                    )
                )
            )
            .navigationTitle(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.title",
                    defaultValue: "Choose Folder"
                )
            )
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileTaskDirectoryPickerCancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    if !isSearchMode {
                        Button {
                            if let parentPath {
                                navigate(to: parentPath)
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(parentPath == nil)
                        .accessibilityLabel(
                            L10n.string(
                                "mobile.taskComposer.directoryPicker.browse.parent",
                                defaultValue: "Parent Folder"
                            )
                        )
                        .accessibilityIdentifier("MobileTaskDirectoryBrowseParent")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isSearchMode, let currentPath {
                    chooseCurrentFolderAction(path: currentPath)
                }
            }
            .task(id: SearchRequest(query: query, retryGeneration: searchRetryGeneration)) {
                await updateRemoteSuggestions()
            }
            .task(id: browseState.pendingRequest) {
                await loadPendingDirectoryRequest()
            }
        }
    }

    @ViewBuilder
    private var browseContent: some View {
        quickLocations
        currentLocationCard

        if let browseFailure, !isLoadingDirectory {
            browseFailureCard(browseFailure)
        }

        if isLoadingDirectory, browseEntries.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.loading",
                        defaultValue: "Loading folders…"
                    )
                )
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .accessibilityElement(children: .combine)
        } else if browseEntries.isEmpty, browseFailure == nil {
            ContentUnavailableView(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.browse.empty.title",
                    defaultValue: "No Subfolders"
                ),
                systemImage: "folder",
                description: Text(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.empty.message",
                        defaultValue: "You can still use this folder for the new workspace."
                    )
                )
            )
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if !browseEntries.isEmpty {
            VStack(spacing: 0) {
                ForEach(browseEntries, id: \.path) { entry in
                    Button {
                        if let destination = browseState.navigationDestination(for: entry) {
                            navigate(to: destination)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            directoryIcon(for: entry)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(entry.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)

                            if !entry.isReadable {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                            }
                            if entry.isReadable {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 58)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isReadable)
                    .accessibilityLabel(entry.name)
                    .accessibilityValue(entry.path)
                    .accessibilityHint(
                        entry.isReadable
                            ? L10n.string(
                                "mobile.taskComposer.directoryPicker.browse.open.hint",
                                defaultValue: "Shows the folders inside this folder."
                            )
                            : browseFailureMessage(.unreadable)
                    )

                    if entry.path != browseEntries.last?.path {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }

            if browseFailure == nil, nextOffset != nil {
                Button {
                    browseState.requestNextPage()
                } label: {
                    HStack(spacing: 8) {
                        if isLoadingDirectory {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                        Text(
                            L10n.string(
                                "mobile.taskComposer.directoryPicker.browse.more",
                                defaultValue: "Show More"
                            )
                        )
                        Spacer()
                        Text("\(browseEntries.count)/\(totalCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .disabled(isLoadingDirectory)
                .accessibilityIdentifier("MobileTaskDirectoryBrowseMore")
            }
        }
    }

    private var quickLocations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                locationChip(
                    title: L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.home",
                        defaultValue: "Home"
                    ),
                    systemImage: "house.fill",
                    path: "~",
                    identifier: "MobileTaskDirectoryBrowseHome"
                )
                locationChip(
                    title: L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.computer",
                        defaultValue: "Computer"
                    ),
                    systemImage: "internaldrive.fill",
                    path: "/",
                    identifier: "MobileTaskDirectoryBrowseComputer"
                )

                ForEach(Array(candidates.prefix(5).enumerated()), id: \.element.id) { index, candidate in
                    let displayPath = TaskComposerDirectoryDisplayPath(path: candidate.path)
                    locationChip(
                        title: displayPath.name,
                        systemImage: "clock.arrow.circlepath",
                        path: candidate.path,
                        identifier: "MobileTaskDirectoryRecent\(index)"
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .contentMargins(.horizontal, 1, for: .scrollContent)
    }

    private var currentLocationCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(currentDirectoryName)
                    .font(.headline)
                    .lineLimit(1)
                Text(browseState.displayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileTaskDirectoryBrowseCurrent")
    }

    @ViewBuilder
    private var searchContent: some View {
        Label {
            Text(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.search.coverage",
                    defaultValue: "Search checks indexed folders across mounted volumes. Browse to reach unindexed or restricted locations."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 2)

        if let searchFailure, !isSearchingMac {
            searchFailureCard(searchFailure)
        }

        if searchSuggestions.isEmpty, !isSearchingMac, searchFailure == nil {
            ContentUnavailableView(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.search.empty.title",
                    defaultValue: "No Indexed Matches"
                ),
                systemImage: "folder.badge.questionmark",
                description: Text(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.search.empty.message",
                        defaultValue: "Browse the Mac to reach folders outside its search index."
                    )
                )
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if !searchSuggestions.isEmpty {
            VStack(spacing: 0) {
                ForEach(searchSuggestions) { suggestion in
                    let displayPath = TaskComposerDirectoryDisplayPath(path: suggestion.path)
                    Button {
                        choose(path: suggestion.path)
                    } label: {
                        TaskComposerDirectorySuggestionRow(
                            displayPath: displayPath,
                            sourceLabel: sourceLabel(for: suggestion.bestSource),
                            context: suggestion.context,
                            isSelected: suggestion.id == selectedPathID
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(displayPath.name)
                    .accessibilityValue(accessibilityValue(for: suggestion))
                    .accessibilityHint(
                        L10n.string(
                            "mobile.taskComposer.directoryPicker.result.hint",
                            defaultValue: "Uses this folder for the new workspace."
                        )
                    )
                    .accessibilityAddTraits(suggestion.id == selectedPathID ? .isSelected : [])

                    if suggestion.id != searchSuggestions.last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
        }

        if isSearchingMac {
            HStack(spacing: 10) {
                ProgressView()
                Text(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.searching",
                        defaultValue: "Searching this Mac…"
                    )
                )
                .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        }

        if let searchStatusMessage {
            Label(searchStatusMessage, systemImage: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("MobileTaskDirectorySearchStatus")
        }
    }

    private func chooseCurrentFolderAction(path: String) -> some View {
        Button {
            choose(path: path)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder.badge.checkmark")
                Text(
                    String(
                        format: L10n.string(
                            "mobile.taskComposer.directoryPicker.browse.useFormat",
                            defaultValue: "Use “%@”"
                        ),
                        currentDirectoryName
                    )
                )
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .mobileGlassProminentButton()
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("MobileTaskDirectoryBrowseUseCurrent")
    }

    private func locationChip(
        title: String,
        systemImage: String,
        path: String,
        identifier: String
    ) -> some View {
        Button {
            navigate(to: path)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(Color.primary.opacity(0.055), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func directoryIcon(for entry: MobileTaskDirectoryListEntry) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: entry.isPackage ? "shippingbox.fill" : "folder.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(entry.isReadable ? Color.accentColor : Color.orange)
                .frame(width: 34, height: 34)
                .background(
                    (entry.isReadable ? Color.accentColor : Color.orange).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            if entry.isSymbolicLink {
                Image(systemName: "arrow.trianglehead.turn.up.right.diamond.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 3, y: 2)
            } else if entry.isHidden {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 3, y: 2)
            }
        }
        .accessibilityHidden(true)
    }

    private var isSearchMode: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentPath: String? {
        browseState.snapshot?.currentPath
    }

    private var parentPath: String? {
        browseState.snapshot?.parentPath
    }

    private var browseEntries: [MobileTaskDirectoryListEntry] {
        browseState.snapshot?.entries ?? []
    }

    private var nextOffset: Int? {
        browseState.snapshot?.nextOffset
    }

    private var totalCount: Int {
        browseState.snapshot?.totalCount ?? 0
    }

    private var isLoadingDirectory: Bool {
        browseState.isLoading
    }

    private var browseFailure: MobileTaskDirectoryListFailure? {
        browseState.failure?.reason
    }

    private var currentDirectoryName: String {
        let path = browseState.displayPath
        guard path != "/" else {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.browse.computer",
                defaultValue: "Computer"
            )
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || path == "~" ? path : name
    }

    private var searchSuggestions: [MobileTaskDirectoryCandidate] {
        let localSuggestions = MobileTaskDirectorySuggestionIndex(candidates: candidates)
            .suggestions(matching: query)
        let remoteCandidates = (searchResponse?.directories ?? []).map {
            MobileTaskDirectoryCandidate(path: $0, source: .filesystemSearch, context: nil)
        }
        var seen = Set<MobileTaskDirectoryPathID>()
        return (remoteCandidates + localSuggestions).filter { seen.insert($0.id).inserted }
    }

    private var searchStatusMessage: String? {
        guard let searchResponse else { return nil }
        if searchResponse.truncated {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.search.truncated",
                defaultValue: "More indexed folders match. Refine your search to see them."
            )
        }
        if searchResponse.searchScope != .allIndexedVolumes {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.search.limited",
                defaultValue: "This Mac returned limited search results. Browse to reach every accessible folder."
            )
        }
        if !searchResponse.gatheringComplete {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.search.partial",
                defaultValue: "The Mac search index did not finish in time. Refine your search or retry."
            )
        }
        return nil
    }

    @MainActor
    private func loadPendingDirectoryRequest() async {
        guard let request = browseState.pendingRequest else { return }
        let result = await listMac(request.path, request.offset)
        guard !Task.isCancelled else {
            browseState.cancel(request)
            return
        }
        browseState.resolve(result, for: request)
    }

    @MainActor
    private func updateRemoteSuggestions() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            searchResponse = nil
            isSearchingMac = false
            searchFailure = nil
            return
        }
        searchResponse = nil
        searchFailure = nil
        isSearchingMac = true
        do {
            // The cancellable delay is the search debounce itself, not synchronization.
            try await Task.sleep(for: .milliseconds(140))
            let result = await searchMac(trimmedQuery)
            guard !Task.isCancelled else { return }
            switch result {
            case let .success(response):
                searchResponse = response
                searchFailure = nil
            case .failure(.cancelled):
                searchResponse = nil
                searchFailure = nil
            case let .failure(failure):
                searchResponse = nil
                searchFailure = failure
            }
            isSearchingMac = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            searchResponse = nil
            searchFailure = .rejected
            isSearchingMac = false
        }
    }

    private func navigate(to path: String) {
        browseState.navigate(to: path)
    }

    private func choose(path: String) {
        select(path)
        dismiss()
    }

    private func searchFailureCard(_ failure: MobileTaskDirectorySearchFailure) -> some View {
        failureCard(
            title: L10n.string(
                "mobile.taskComposer.directoryPicker.failure.title",
                defaultValue: "Couldn’t Search Folders"
            ),
            message: searchFailureMessage(failure),
            retry: { searchRetryGeneration &+= 1 },
            identifier: "TaskComposerDirectorySearchRetry"
        )
    }

    private func browseFailureCard(_ failure: MobileTaskDirectoryListFailure) -> some View {
        failureCard(
            title: browseFailureTitle(failure),
            message: browseFailureMessage(failure),
            retry: { browseState.retryFailedRequest() },
            identifier: "TaskComposerDirectoryBrowseRetry"
        )
    }

    private func failureCard(
        title: String,
        message: String,
        retry: @escaping () -> Void,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.folder.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: retry) {
                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Color.accentColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier(identifier)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
        }
    }

    private func searchFailureMessage(_ failure: MobileTaskDirectorySearchFailure) -> String {
        switch failure {
        case .unsupported:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.unsupported",
                defaultValue: "Update cmux on this Mac to search its folders. You can still choose a recent location."
            )
        case .unavailable:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.unavailable",
                defaultValue: "Reconnect to this Mac, then try again."
            )
        case .timedOut:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.timeout",
                defaultValue: "This Mac took too long to search. Try again."
            )
        case .authorizationRequired:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.authorization",
                defaultValue: "Sign in again on this device and Mac, then retry."
            )
        case .rejected, .cancelled:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.generic",
                defaultValue: "The folder search failed. Try again."
            )
        }
    }

    private func browseFailureTitle(_ failure: MobileTaskDirectoryListFailure) -> String {
        if browseState.failure?.request.kind == .append {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.browse.more.failure.title",
                defaultValue: "Couldn’t Load More Folders"
            )
        }
        return switch failure {
        case .permissionDenied, .unreadable:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.access.title",
                defaultValue: "Folder Access Needed"
            )
        case .unsupported:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.update.title",
                defaultValue: "Update cmux on This Mac"
            )
        default:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.title",
                defaultValue: "Couldn’t Open Folder"
            )
        }
    }

    private func browseFailureMessage(_ failure: MobileTaskDirectoryListFailure) -> String {
        switch failure {
        case .invalidPath:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.invalid",
                defaultValue: "Choose another location and try again."
            )
        case .unavailable:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.unavailable",
                defaultValue: "Reconnect to this Mac, then try again."
            )
        case .timedOut:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.timeout",
                defaultValue: "This folder took too long to load. Check the Mac or network volume, then retry."
            )
        case .authorizationRequired:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.authorization",
                defaultValue: "Sign in again on this device and Mac, then retry."
            )
        case .unsupported:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.update.message",
                defaultValue: "Install the latest cmux on the Mac to browse every accessible folder."
            )
        case .notFound, .notDirectory:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.missing",
                defaultValue: "This folder moved or no longer exists. Choose another location."
            )
        case .permissionDenied:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.permission",
                defaultValue: "Allow cmux to access this location on the Mac, then retry."
            )
        case .unreadable:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.unreadable",
                defaultValue: "The Mac can see this folder but cannot read its contents."
            )
        case .rejected, .cancelled:
            L10n.string(
                "mobile.taskComposer.directoryPicker.browse.failure.generic",
                defaultValue: "The Mac could not list this folder. Try again."
            )
        }
    }

    private func detail(for suggestion: MobileTaskDirectoryCandidate) -> String {
        [sourceLabel(for: suggestion.bestSource), suggestion.context]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func accessibilityValue(for suggestion: MobileTaskDirectoryCandidate) -> String {
        [suggestion.path, detail(for: suggestion)].formatted()
    }

    private func sourceLabel(for source: MobileTaskDirectorySource) -> String {
        switch source {
        case .filesystemSearch:
            L10n.string("mobile.taskComposer.directoryPicker.source.filesystem", defaultValue: "On this Mac")
        case .activeTerminal:
            L10n.string("mobile.taskComposer.directoryPicker.source.activeTerminal", defaultValue: "Focused terminal")
        case .activeWorkspace:
            L10n.string("mobile.taskComposer.directoryPicker.source.activeWorkspace", defaultValue: "Current workspace")
        case .templateDefault:
            L10n.string("mobile.taskComposer.directoryPicker.source.template", defaultValue: "Template default")
        case .lastSuccessful:
            L10n.string("mobile.taskComposer.directoryPicker.source.last", defaultValue: "Last used")
        case .openWorkspace, .openTerminal:
            L10n.string("mobile.taskComposer.directoryPicker.source.open", defaultValue: "Open on this Mac")
        case .recentSuccessful:
            L10n.string("mobile.taskComposer.directoryPicker.source.recent", defaultValue: "Recent task")
        case .home:
            L10n.string("mobile.taskComposer.directoryPicker.source.home", defaultValue: "Home folder")
        }
    }

    private struct SearchRequest: Hashable {
        let query: String
        let retryGeneration: Int
    }

}
#endif
