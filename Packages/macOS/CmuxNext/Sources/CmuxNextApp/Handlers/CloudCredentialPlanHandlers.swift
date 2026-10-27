import CmuxNextActions
import CmuxNextCompat

/// A read-only action: even confirmation authorizes only displaying the plan. The person
/// runs its commands in their own local/Cloud terminal. No token enters an action argument.
enum CloudCredentialPlanHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        CloudHandlers.bind("cloudCredentialPlan", registry, reason: { nil }) { invocation in
            let session = try CloudHandlers.machine(invocation, context)
            let plan = try CloudCredentialPlan(machineID: session.machineID, confirmed: invocation.isConfirmed)
            CloudHandlers.result("credential setup plan", context) { plan.fields }
        }
    }
}
