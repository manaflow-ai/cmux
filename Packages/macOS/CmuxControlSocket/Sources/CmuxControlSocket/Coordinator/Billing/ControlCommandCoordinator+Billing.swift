extension ControlCommandCoordinator {
    nonisolated func billingStatus(context: (any ControlCommandContext)?) -> ControlCallResult {
        guard let context = context as? any ControlBillingContext else {
            return .ok(.object(["ok": .bool(false), "error": .string("unavailable")]))
        }
        return context.controlBillingStatus()
    }

    nonisolated func billingCheckout(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        let plan = string(params, "plan") ?? "pro"
        guard plan == "pro" || plan == "team" else {
            return .ok(.object([
                "ok": .bool(false),
                "error": .string("invalid_plan"),
                "billing": .string("invalid_plan"),
            ]))
        }
        guard let context = context as? any ControlBillingContext else {
            return .ok(.object(["ok": .bool(false), "error": .string("unavailable")]))
        }
        return context.controlBillingCheckout(plan: plan)
    }

    nonisolated func billingPortal(context: (any ControlCommandContext)?) -> ControlCallResult {
        guard let context = context as? any ControlBillingContext else {
            return .ok(.object(["ok": .bool(false), "error": .string("unavailable")]))
        }
        return context.controlBillingPortal()
    }
}
