//! `acpmux daemon placement JSON`: the client side of `_acpmux/tailnet/placement`. It checks the
//! message against this build's `PlacementMessage` (so a typo fails here, not in the daemon),
//! sends it, and prints the daemon's `PlacementReply`.

use anyhow::{Context as _, Result};
use cmux_tailnet_front::{PlacementMessage, PlacementReply};

use crate::rpc::method;

pub async fn run(message: &str) -> Result<()> {
    let message: PlacementMessage =
        serde_json::from_str(message).context("not a placement message")?;
    let client = crate::daemon::connect(false).await?;
    let answer =
        client.request(method::MUX_TAILNET_PLACEMENT, serde_json::to_value(&message)?).await?;
    // Validated, but printed as sent: a newer daemon's extra fields stay visible.
    serde_json::from_value::<PlacementReply>(answer.clone()).context("not a placement reply")?;
    crate::cli::output::print_json(&answer);
    Ok(())
}
