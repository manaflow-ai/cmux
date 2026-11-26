use super::*;

fn ids(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| (*name).to_owned()).collect()
}

fn legs(pairs: &[(&str, Leg)]) -> HashMap<String, Leg> {
    pairs.iter().map(|(id, leg)| ((*id).to_owned(), *leg)).collect()
}

use Leg::{Dead, Measured};

/// No measurement on either side: the service's order, untouched (today's).
#[test]
fn no_measurements_keep_the_listed_order() {
    let relays = ids(&["a", "b", "c"]);
    assert_eq!(rank(&relays, &HashMap::new(), &HashMap::new(), None), relays);
    assert_eq!(rank(&relays, &HashMap::new(), &HashMap::new(), Some("c")), relays);
}

/// The pair's best relay is the lowest sum of both legs, not either side's
/// nearest: a phone in Europe and a Mac in the US meet in the middle.
#[test]
fn picks_the_lowest_sum_of_both_legs() {
    let relays = ids(&["eu", "us", "mid"]);
    let phone = legs(&[("eu", Measured(10)), ("us", Measured(140)), ("mid", Measured(45))]);
    let mac = legs(&[("eu", Measured(150)), ("us", Measured(8)), ("mid", Measured(50))]);
    assert_eq!(rank(&relays, &phone, &mac, None), ids(&["mid", "us", "eu"]));
}

/// Both ends compute the same order from their swapped views, so they agree
/// on a relay without negotiating, ties included.
#[test]
fn both_ends_agree() {
    let relays = ids(&["a", "b", "c", "d"]);
    let one = legs(&[("a", Measured(30)), ("b", Measured(20)), ("c", Measured(5)), ("d", Dead)]);
    let two = legs(&[("a", Measured(10)), ("b", Measured(20)), ("c", Measured(35))]);
    assert_eq!(rank(&relays, &one, &two, None), rank(&relays, &two, &one, None));
    assert_eq!(rank(&relays, &one, &two, None), ids(&["a", "b", "c", "d"]));
}

/// A measured relay goes ahead of one nobody measured, unless it is slower
/// than the estimate.
#[test]
fn measured_beats_estimate() {
    let relays = ids(&["unmeasured", "measured"]);
    let own = legs(&[("measured", Measured(60))]);
    assert_eq!(rank(&relays, &own, &HashMap::new(), None), ids(&["measured", "unmeasured"]));
    let slow = legs(&[("measured", Measured(ESTIMATE_MS + 50))]);
    assert_eq!(rank(&relays, &slow, &HashMap::new(), None), ids(&["unmeasured", "measured"]));
}

/// Jitter never moves a pair: the carrying relay stays first until the best
/// beats it by the margin, then the pair moves (it does not stay on its first
/// relay because it was first).
#[test]
fn hysteresis_holds_then_moves() {
    let relays = ids(&["a", "b"]);
    let far = legs(&[("a", Measured(20)), ("b", Measured(20))]);
    // b is 8 ms better (under SWITCH_MARGIN_MS): a keeps the pair.
    let own = legs(&[("a", Measured(40)), ("b", Measured(32))]);
    assert_eq!(rank(&relays, &own, &far, Some("a")), ids(&["a", "b"]));
    assert_eq!(rank(&relays, &own, &far, None), ids(&["b", "a"]));
    // The phone's leg to a grew (it left Wi-Fi): b wins by more than the margin.
    let moved = legs(&[("a", Measured(90)), ("b", Measured(32))]);
    assert_eq!(rank(&relays, &moved, &far, Some("a")), ids(&["b", "a"]));
    // The percentage margin: on a 300 ms pair, 40 ms better is under 20 %.
    let far = legs(&[("a", Measured(150)), ("b", Measured(150))]);
    let own = legs(&[("a", Measured(150)), ("b", Measured(110))]);
    assert_eq!(rank(&relays, &own, &far, Some("a")), ids(&["a", "b"]));
}

/// A relay that stopped answering goes behind every live one, and does not
/// keep the pair through the hysteresis.
#[test]
fn a_dead_relay_goes_last_and_loses_the_pair() {
    let relays = ids(&["a", "b", "c"]);
    let own = legs(&[("a", Dead), ("b", Measured(80)), ("c", Measured(30))]);
    assert_eq!(rank(&relays, &own, &HashMap::new(), Some("a")), ids(&["c", "b", "a"]));
    // Dead on the far side only.
    let far = legs(&[("c", Dead)]);
    let own = legs(&[("a", Measured(40)), ("b", Measured(50)), ("c", Measured(5))]);
    assert_eq!(rank(&relays, &own, &far, Some("c")), ids(&["a", "b", "c"]));
}

/// A carrying relay no longer offered is ignored.
#[test]
fn an_unlisted_current_relay_is_ignored() {
    let relays = ids(&["a", "b"]);
    let own = legs(&[("a", Measured(50)), ("b", Measured(10))]);
    assert_eq!(rank(&relays, &own, &HashMap::new(), Some("gone")), ids(&["b", "a"]));
}

/// The wire vector round-trips: a dead relay goes out as DEAD_MS and comes
/// back dead; an empty vector (an older peer) changes nothing.
#[test]
fn far_vectors_round_trip_and_an_older_peer_changes_nothing() {
    let peer = "relay-rank-test-peer";
    let mut vector = BTreeMap::new();
    vector.insert("a".to_owned(), 20);
    vector.insert("b".to_owned(), DEAD_MS);
    note_far(peer, &vector);
    note_far(peer, &BTreeMap::new());
    let relays = ids(&["b", "a"]);
    assert_eq!(ranked_for(&relays, Some(peer)), ids(&["a", "b"]));
    assert_eq!(ranked_for(&relays, Some("relay-rank-unknown-peer")).len(), 2);
}

/// The moving average: a single slow probe does not swing a leg all the way.
#[test]
fn own_legs_average_and_die() {
    let mut table = Table::default();
    note_own(&mut table, "a", Some(20));
    note_own(&mut table, "a", Some(100));
    assert_eq!(table.own.get("a"), Some(&Measured(60)));
    note_own(&mut table, "a", None);
    assert_eq!(table.own.get("a"), Some(&Dead));
    note_own(&mut table, "a", Some(30));
    assert_eq!(table.own.get("a"), Some(&Measured(30)));
}

/// The probe times a STUN answer with the request's transaction id, and a
/// relay that never answers is None (dead).
#[tokio::test]
async fn probe_measures_an_answering_relay_and_not_a_silent_one() {
    let server = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let address = server.local_addr().unwrap().to_string();
    tokio::spawn(async move {
        let mut buf = [0u8; 1500];
        while let Ok((n, from)) = server.recv_from(&mut buf).await {
            // Answer with the request's own bytes: same transaction id.
            let _ = server.send_to(&buf[..n], from).await;
        }
    });
    let answered = probe(&address).await;
    assert!(answered.is_some_and(|ms| ms < PROBE_WAIT.as_millis() as u32), "{answered:?}");

    let silent = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let address = silent.local_addr().unwrap().to_string();
    assert_eq!(probe(&address).await, None);
    drop(silent);
}
