import AppKit
import CmuxNextPages

/// A read the store shows: not asked yet, on its way, its value, or why it failed.
nonisolated enum AppStoreLoad<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? { if case .loaded(let value) = self { value } else { nil } }
    var isLoading: Bool { if case .loading = self { true } else { false } }
}

/// The native App Store's view state: which tab and listing show, and the owner's last replies. Every list,
/// section and listing is the Rust owner's (``AppStoreOps``); this keeps what came back and what the person
/// picked, nothing more. Replies to an older request than the newest of their kind are dropped.
@MainActor
final class AppStoreModel {
    private let ops: any AppStoreOps
    /// Runs after any change the views draw.
    var onChange: (() -> Void)?
    private var started = false

    private(set) var tab: AppStoreTab.Native = .discover
    /// The listing on top of the tab, by app id.
    private(set) var listing: String?
    private(set) var query = ""
    private(set) var catalog: AppStoreLoad<[AppStoreItem]> = .idle
    /// The owner's shelves; nil when the owner serves none (an owner older than `catalog.sections`).
    private(set) var sections: [AppStoreSection]?
    private(set) var searchResults: AppStoreLoad<[AppStoreItem]> = .idle
    private(set) var category: String?
    private(set) var categoryItems: AppStoreLoad<[AppStoreItem]> = .idle
    private(set) var installed: AppStoreLoad<[AppStoreInstalledRow]> = .idle
    private(set) var updates: AppStoreLoad<[AppStoreUpdate]> = .idle
    /// What's New per app on the Updates tab (from `catalog.get`).
    private(set) var updateNotes: [String: AppStoreWhatsNew] = [:]
    private(set) var detail: AppStoreLoad<AppStoreDetail> = .idle
    /// The open listing's screenshots, in the owner's order (a failed one is left out).
    private(set) var screenshots: [NSImage] = []
    /// The screenshot the listing's carousel shows.
    private(set) var shotIndex = 0
    private(set) var icons: [String: NSImage] = [:]
    /// Apps with a change on its way: their buttons wait.
    private(set) var busy: Set<String> = []
    /// A one-line notice over the tab (a deep link to an app the store does not have).
    private(set) var notice: String?
    /// The last refused change, until the next one.
    private(set) var error: String?

    // The Community tab (`source: "community"`).
    private(set) var community: AppStoreLoad<AppStoreCommunityPage> = .idle
    /// `extension`, `setup`, or nil for both.
    private(set) var communityKind: String?
    private(set) var communitySort = "featured"
    /// The community listing on top of the Community tab, by its ref.
    private(set) var communityRef: String?
    private(set) var communityDetail: AppStoreLoad<AppStoreCommunityDetail> = .idle
    /// The open community listing's README and changelog, parsed off the main actor.
    private(set) var communityReadme: [AppStoreMarkdownBlock] = []
    private(set) var communityChangelog: [AppStoreMarkdownBlock] = []

    private static let maxPages = 50
    private var generations: [String: Int] = [:]
    private var iconRequests: Set<String> = []

    init(ops: any AppStoreOps) {
        self.ops = ops
    }

    /// Reads everything the tabs show and follows the owner's changes from here on.
    func start() {
        guard !started else { return }
        started = true
        ops.observeChanges(owner: self) { [weak self] in self?.reload() }
        reload()
    }

    /// Reads the lists again (the owner's install mirror moved, or Retry).
    func reload() {
        loadCatalog()
        loadSections()
        loadInstalled()
        loadUpdates()
        if !query.isEmpty, tab != .community { search(query) }
        if let category { loadCategory(category) }
        if let listing { loadDetail(listing, showsLoading: false) }
        if community.value != nil || tab == .community { loadCommunity(refresh: false) }
        if let communityRef { loadCommunityDetail(communityRef, showsLoading: false) }
    }

    // MARK: Navigation

    func show(tab: AppStoreTab.Native) {
        self.tab = tab
        listing = nil
        communityRef = nil
        notice = nil
        if tab == .community, community.value == nil, !community.isLoading { loadCommunity(refresh: false) }
        changed()
    }

    // MARK: Community

    /// Shows community listings of `kind` (nil: extensions and setups).
    func filterCommunity(kind: String?) {
        guard kind != communityKind else { return }
        communityKind = kind
        loadCommunity(refresh: false)
    }

    func sortCommunity(_ sort: String) {
        guard sort != communitySort, AppStoreCommunityWire.sorts.contains(sort) else { return }
        communitySort = sort
        loadCommunity(refresh: false)
    }

    /// Reads the community list from the owner's cache; `refresh` asks the owner to fetch again (Retry).
    /// The owner never waits on the network: a stale cache answers at once and says so.
    func loadCommunity(refresh: Bool) {
        let ticket = begin("community")
        if community.value == nil { community = .loading }
        changed()
        let query = tab == .community ? self.query : ""
        let kind = communityKind
        let sort = communitySort
        Task { [weak self, ops] in
            var rows: [AppStoreCommunityRow] = []
            var first: AppStoreCommunityPage?
            var cursor: String?
            var failure: String?
            for _ in 0..<Self.maxPages {
                let args = AppStoreCommunityWire.listArgs(query: query, kind: kind, sort: sort, refresh: refresh && cursor == nil, cursor: cursor)
                do throws(AppsClientError) {
                    let reply = AppStoreCommunityWire.page(try await ops.read(AppStoreWire.catalogList, args: args))
                    if first == nil { first = reply.page }
                    rows += reply.page.rows
                    cursor = reply.next
                } catch {
                    failure = error.description
                    break
                }
                if cursor == nil { break }
            }
            guard let self, current("community", ticket) else { return }
            if var page = first {
                page.rows = rows
                community = .loaded(page)
            } else if let failure {
                if community.value == nil { community = .failed(failure) }
            }
            changed()
        }
    }

    /// Opens a community listing (README, versions, Install).
    func selectCommunity(_ ref: String) {
        communityRef = ref
        notice = nil
        loadCommunityDetail(ref, showsLoading: true)
    }

    /// Installs a community row (`apps.install {app: install_app}`) behind the consent card, as any install.
    func installCommunity(_ row: AppStoreCommunityRow) {
        guard let app = row.installApp else { return }
        change(.install, app: app)
    }

    private func loadCommunityDetail(_ ref: String, showsLoading: Bool) {
        let ticket = begin("communityDetail")
        if showsLoading { communityDetail = .loading }
        changed()
        Task { [weak self, ops] in
            let result: AppStoreLoad<AppStoreCommunityDetail>
            var readme: [AppStoreMarkdownBlock] = []
            var changelog: [AppStoreMarkdownBlock] = []
            do throws(AppsClientError) {
                let reply = try await ops.read(AppStoreWire.catalogGet, args: ["source": .string(AppStoreCommunityWire.source), "ref": .string(ref)])
                result = AppStoreCommunityDetail(json: reply).map { .loaded($0) } ?? .failed(AppStoreStrings.notFound)
                if let detail = result.value {
                    (readme, changelog) = await Task.detached(priority: .userInitiated) {
                        (AppStoreMarkdownBlock.parse(detail.readme), AppStoreMarkdownBlock.parse(detail.changelog ?? ""))
                    }.value
                }
            } catch {
                result = .failed(error.description)
            }
            guard let self, current("communityDetail", ticket), communityRef == ref else { return }
            if case .failed = result, !showsLoading, communityDetail.value != nil { return }
            communityDetail = result
            communityReadme = readme
            communityChangelog = changelog
            changed()
        }
    }

    /// Opens `app`'s listing over the current tab.
    func select(_ app: String) {
        listing = app
        notice = nil
        screenshots = []
        shotIndex = 0
        loadDetail(app, showsLoading: true)
    }

    /// Shows screenshot `index` in the listing's carousel.
    func showShot(_ index: Int) {
        guard screenshots.indices.contains(index), index != shotIndex else { return }
        shotIndex = index
        changed()
    }

    /// Back from a listing (or a category's list) to the tab.
    func back() {
        if listing != nil { listing = nil } else if communityRef != nil { communityRef = nil } else { category = nil }
        changed()
    }

    func search(_ text: String) {
        let next = text.trimmingCharacters(in: .whitespaces)
        if tab == .community {
            // The Community tab searches the community list (the owner's `query`).
            guard next != query else { return }
            query = next
            communityRef = nil
            return loadCommunity(refresh: false)
        }
        query = next
        guard !query.isEmpty else {
            searchResults = .idle
            return changed()
        }
        listing = nil
        let ticket = begin("search")
        searchResults = .loading
        changed()
        let args: AppJSON = ["query": .string(query), "limit": .number(Double(AppStoreWire.pageSize))]
        Task { [weak self, ops] in
            let result = await Self.readPage(ops, args: args)
            guard let self, current("search", ticket) else { return }
            searchResults = result
            loadIcons(result.value ?? [])
            changed()
        }
    }

    func open(category: String) {
        self.category = category
        loadCategory(category)
    }

    // MARK: Changes

    func change(_ kind: AppStoreChangeKind, app: String) {
        guard !busy.contains(app) else { return }
        busy.insert(app)
        error = nil
        changed()
        Task { [weak self, ops] in
            let outcome = await ops.change(kind, app: app)
            guard let self else { return }
            busy.remove(app)
            if case .refused(_, let message) = outcome { error = message }
            reload()
        }
    }

    func setHidden(_ app: String, hidden: Bool) {
        guard !busy.contains(app) else { return }
        busy.insert(app)
        error = nil
        changed()
        Task { [weak self, ops] in
            var failure: String?
            do throws(AppsClientError) { try await ops.setHidden(app, hidden: hidden) } catch { failure = error.description }
            guard let self else { return }
            busy.remove(app)
            error = failure
            reload()
        }
    }

    /// Updates every app the Updates tab lists, one after another (each behind its own card).
    func updateAll() {
        let apps = (updates.value ?? []).map(\.id).filter { !busy.contains($0) }
        guard !apps.isEmpty else { return }
        busy.formUnion(apps)
        error = nil
        changed()
        Task { [weak self, ops] in
            for app in apps {
                let outcome = await ops.change(.update, app: app)
                self?.busy.remove(app)
                if case .refused(_, let message) = outcome { self?.error = message }
                if case .declined = outcome { break }
            }
            guard let self else { return }
            busy.subtract(apps)
            reload()
        }
    }

    func open(_ app: String) { ops.open(app) }
    func openLink(_ url: URL) { ops.openLink(url) }

    // MARK: Lookups the views use

    /// The catalog row of `app`, when the catalog has it.
    func item(_ app: String) -> AppStoreItem? { catalogByID[app] }

    /// The rows of `section` the catalog knows and Discover shows, in the owner's order.
    func items(of section: AppStoreSection) -> [AppStoreItem] {
        section.apps.compactMap { catalogByID[$0] }.filter(\.presentable)
    }

    /// Discover's rows (the store shelf, presentable).
    var storeItems: [AppStoreItem] { (catalog.value ?? []).filter(\.presentable) }

    private var catalogByID: [String: AppStoreItem] = [:]

    // MARK: Reads

    private func loadCatalog() {
        let ticket = begin("catalog")
        if catalog.value == nil { catalog = .loading }
        changed()
        Task { [weak self, ops] in
            let result = await Self.readPage(ops, args: ["limit": .number(Double(AppStoreWire.pageSize))])
            guard let self, current("catalog", ticket) else { return }
            if case .failed = result, catalog.value != nil { return changed() }
            catalog = result
            catalogByID = Dictionary((result.value ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            loadIcons(result.value ?? [])
            changed()
        }
    }

    private func loadSections() {
        let ticket = begin("sections")
        Task { [weak self, ops] in
            let reply: AppJSON?
            do throws(AppsClientError) { reply = try await ops.read(AppStoreWire.catalogSections, args: .object([:])) } catch { reply = nil }
            guard let self, current("sections", ticket) else { return }
            sections = reply.map(AppStoreWire.sections)
            changed()
        }
    }

    private func loadInstalled() {
        let ticket = begin("installed")
        if installed.value == nil { installed = .loading }
        Task { [weak self, ops] in
            let result: AppStoreLoad<[AppStoreInstalledRow]>
            do throws(AppsClientError) {
                result = .loaded(AppStoreWire.installed(try await ops.read(AppStoreWire.installedList, args: .object([:]))))
            } catch {
                result = .failed(error.description)
            }
            guard let self, current("installed", ticket) else { return }
            installed = result
            changed()
        }
    }

    /// `updates.list`; an owner without it answers from the installed rows' `update` (as the React page does).
    private func loadUpdates() {
        let ticket = begin("updates")
        if updates.value == nil { updates = .loading }
        Task { [weak self, ops] in
            var result: AppStoreLoad<[AppStoreUpdate]>
            do throws(AppsClientError) {
                result = .loaded(AppStoreWire.updates(try await ops.read(AppStoreWire.updatesList, args: .object([:]))))
            } catch {
                do throws(AppsClientError) {
                    let rows = AppStoreWire.installed(try await ops.read(AppStoreWire.installedList, args: .object([:])))
                    result = .loaded(rows.compactMap { row in row.updateVersion.map { AppStoreUpdate(installed: row, version: $0) } })
                } catch {
                    result = .failed(error.description)
                }
            }
            guard let self, current("updates", ticket) else { return }
            updates = result
            changed()
            for update in result.value ?? [] where updateNotes[update.id] == nil { loadNotes(update.id) }
        }
    }

    private func loadNotes(_ app: String) {
        Task { [weak self, ops] in
            let reply: AppJSON?
            do throws(AppsClientError) { reply = try await ops.read(AppStoreWire.catalogGet, args: ["app": .string(app)]) } catch { reply = nil }
            guard let self, let news = reply.flatMap(AppStoreDetail.init(json:))?.whatsNew else { return }
            updateNotes[app] = news
            changed()
        }
    }

    private func loadCategory(_ id: String) {
        let ticket = begin("category")
        categoryItems = .loading
        changed()
        let args: AppJSON = ["category": .string(id), "limit": .number(Double(AppStoreWire.pageSize))]
        Task { [weak self, ops] in
            let result = await Self.readPage(ops, args: args)
            guard let self, current("category", ticket) else { return }
            categoryItems = result
            loadIcons(result.value ?? [])
            changed()
        }
    }

    private func loadDetail(_ app: String, showsLoading: Bool) {
        let ticket = begin("detail")
        if showsLoading { detail = .loading }
        changed()
        Task { [weak self, ops] in
            let result: AppStoreLoad<AppStoreDetail>
            var missing = false
            do throws(AppsClientError) {
                let reply = try await ops.read(AppStoreWire.catalogGet, args: ["app": .string(app)])
                result = AppStoreDetail(json: reply).map { .loaded($0) } ?? .failed(AppStoreStrings.notFound)
            } catch {
                if case .refused(let refusal) = error, let code = refusal.code, code.hasSuffix("unknown") || code.hasSuffix("not_found") {
                    missing = true
                }
                result = .failed(error.description)
            }
            guard let self, current("detail", ticket), listing == app else { return }
            if missing {
                // A deep link to an app the store does not have: Discover, with a notice (as #44805).
                listing = nil
                tab = .discover
                notice = AppStoreStrings.notInStore
                detail = .idle
                return changed()
            }
            let firstLoad = detail.value?.id != app
            detail = result
            changed()
            if let loaded = result.value {
                loadIcons([loaded.item])
                if firstLoad || screenshots.isEmpty { loadScreenshots(loaded, ticket: ticket) }
            }
        }
    }

    private func loadScreenshots(_ detail: AppStoreDetail, ticket: Int) {
        Task { [weak self, ops] in
            var images: [NSImage] = []
            for path in detail.screenshots {
                if let image = await Self.image(ops, app: detail.id, path: path) { images.append(image) }
            }
            guard let self, current("detail", ticket) else { return }
            screenshots = images
            changed()
        }
    }

    /// Loads the package icons no earlier read loaded.
    private func loadIcons(_ items: [AppStoreItem]) {
        for item in items {
            guard case .asset(let path) = item.icon, icons[item.id] == nil, !iconRequests.contains(item.id) else { continue }
            iconRequests.insert(item.id)
            Task { [weak self, ops] in
                let image = await Self.image(ops, app: item.id, path: path)
                guard let self else { return }
                iconRequests.remove(item.id)
                guard let image else { return }
                icons[item.id] = image
                changed()
            }
        }
    }

    // MARK: Helpers

    /// Every page of `catalog.list` with `args`, following the cursor.
    private static func readPage(_ ops: any AppStoreOps, args: AppJSON) async -> AppStoreLoad<[AppStoreItem]> {
        var items: [AppStoreItem] = []
        var cursor: String?
        // At most `maxPages` pages (200 rows each): a cursor that never ends cannot spin.
        for _ in 0..<Self.maxPages {
            var page = args.objectValue ?? [:]
            if let cursor { page["cursor"] = .string(cursor) }
            do throws(AppsClientError) {
                let reply = AppStoreWire.catalogPage(try await ops.read(AppStoreWire.catalogList, args: .object(page)))
                items += reply.items
                cursor = reply.next
            } catch {
                return items.isEmpty ? .failed(error.description) : .loaded(items)
            }
            if cursor == nil { break }
        }
        return .loaded(items)
    }

    /// One package image (`asset.get`), its base64 decoded off the main actor.
    private static func image(_ ops: any AppStoreOps, app: String, path: String) async -> NSImage? {
        let reply: AppJSON
        do throws(AppsClientError) { reply = try await ops.read(AppStoreWire.assetGet, args: ["app": .string(app), "path": .string(path)]) } catch { return nil }
        let data = await Task.detached(priority: .userInitiated) { AppStoreWire.assetData(reply) }.value
        return data.flatMap(NSImage.init(data:))
    }

    private func begin(_ kind: String) -> Int {
        let next = (generations[kind] ?? 0) + 1
        generations[kind] = next
        return next
    }

    private func current(_ kind: String, _ ticket: Int) -> Bool { generations[kind] == ticket }

    private func changed() { onChange?() }
}

extension AppStoreTab {
    /// The native store's five tabs (the React page has two: ``AppStoreTab``).
    nonisolated enum Native: String, CaseIterable, Sendable {
        case today, discover, community, categories, updates, installed

        /// The native tab an `appStore.show --tab` opens.
        init(_ tab: AppStoreTab) {
            switch tab {
            case .discover: self = .discover
            case .installed: self = .installed
            }
        }

        var title: String {
            switch self {
            case .today: AppStoreStrings.today
            case .discover: AppStoreStrings.discover
            case .community: AppStoreStrings.community
            case .categories: AppStoreStrings.categories
            case .updates: AppStoreStrings.updates
            case .installed: AppStoreStrings.installed
            }
        }
    }
}
