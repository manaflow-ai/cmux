/** Freestyle's customer id rule (freestyle@0.2.21 `Customer.customerId`): 1-128 ASCII letters, digits and `_.:@-`. */
const CUSTOMER_ID = /^[A-Za-z0-9_.:@-]{1,128}$/u

/**
 * The `customer` field of a Freestyle VM create (POST /v5/vms, freestyle@0.2.21 CreateVmOptions): the owning team or
 * user id, so Freestyle's abuse protection tells our customers' VMs apart. Inline, so no separate customer upsert has
 * to exist first; it carries the id only (no email or other profile data). Empty for a missing or malformed id: the
 * VM is still made, untagged, as before.
 *
 * The id is the owner each path already tags the VM with, so one owner can be more than one customer: direct Cloud
 * and team VMs use the cmux-next team id, VMs made through the cmux VM API its tenant id
 * (workers/cmux-vm/src/upstream/live-create.ts), and hand and Chief machines the owner's user id.
 */
export const freestyleCustomer = (owner: string | null | undefined): { customer?: { customerId: string } } =>
  owner && CUSTOMER_ID.test(owner) ? { customer: { customerId: owner } } : {}
