# Cloud Mac provisioning blocker

- Run: https://github.com/manaflow-ai/cmux-loader/actions/runs/29870272545
- Requested host: `cmux-loader-29870272545`
- Result: the provisioning wrapper timed out waiting for the Tailscale device.
- Discovery attempted: local Tailscale status and DNS.
- Fallback unavailable: no macfleet Admin API token was configured.
- Cleanup: cancellation requested after the unreachable runner remained in the workflow's hold step.

No SSH alias or GUI-ready provision JSON was produced, so CUA SSH bootstrap and the required full-screen verification video could not be performed.
