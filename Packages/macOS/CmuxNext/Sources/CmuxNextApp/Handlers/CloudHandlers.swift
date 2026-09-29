import CmuxNextActions

/// Cloud and account actions. cmux-next has no Cloud client until the Cloud
/// wave (plans/cmux-next/cloud-ios.md), so every catalog action in the
/// `.cloud` category is typed-unavailable. Listing by category keeps new
/// catalog rows covered until a real handler replaces them.
enum CloudHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let ids = registry.descriptors.filter { $0.category == .cloud && !registry.isBound($0.id) }.map(\.id)
        context.unavailable(ids, HandlerStrings.cloud)
    }
}
