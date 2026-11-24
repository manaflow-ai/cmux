use std::time::Duration;

use serde_json::json;

use super::*;

/// A fake phone on `phones`: answers each request line with `answer`.
fn fake_phone(
    phones: &'static Phones,
    device_id: &str,
    name: &str,
    answer: impl Fn(cmux_phone_page::Request) -> Option<Vec<u8>> + Send + 'static,
) -> u64 {
    let mut attached = phones.attach(device_id, name);
    let key = attached.key;
    tokio::spawn(async move {
        while let Some(line) = attached.requests.recv().await {
            let request = cmux_phone_page::parse_request(&line[..line.len() - 1]).expect("a request line");
            if let Some(reply) = answer(request) {
                attached.answered(&reply[..reply.len() - 1]);
            }
        }
    });
    key
}

fn leak() -> &'static Phones {
    Box::leak(Box::default())
}

#[tokio::test]
async fn no_phone_holding_the_channel_is_refused_at_once() {
    let phones = leak();
    let answer = phones.call(None, "browser.page.state", &json!({"tab": "tab_1"})).await;
    assert_eq!(answer["error"], cmux_phone_page::NOT_LINKED);
    let answer = phones.call(Some("dev-9"), "browser.page.state", &json!({"tab": "tab_1"})).await;
    assert_eq!(answer["error"], cmux_phone_page::NOT_LINKED);
}

#[tokio::test]
async fn a_verb_reaches_the_phone_and_its_answer_comes_back() {
    let phones = leak();
    fake_phone(phones, "dev-1", "Leo's iPhone", |request| {
        assert_eq!(request.tab, "tab_7");
        let script = request.params["script"].as_str().unwrap_or_default().to_owned();
        Some(cmux_phone_page::answer_line(request.id, Ok(json!({"value": script.len()}))))
    });
    assert_eq!(phones.linked().len(), 1);
    let answer = phones.call(None, "browser.page.eval", &json!({"tab": "tab_7", "script": "1+1"})).await;
    assert_eq!(answer, json!({"ok": true, "device_id": "dev-1", "value": {"value": 3}}));
    let answer =
        phones.call(Some("leo's iphone"), "browser.page.eval", &json!({"tab": "tab_7", "script": "x"})).await;
    assert_eq!(answer["value"]["value"], 1);
}

#[tokio::test]
async fn the_phones_refusal_and_an_unsupported_verb_come_back_as_refusals() {
    let phones = leak();
    fake_phone(phones, "dev-1", "", |request| {
        Some(cmux_phone_page::answer_line(request.id, Err((cmux_phone_page::NOT_ON_PHONE, "mirrored"))))
    });
    let answer = phones.call(None, "browser.page.text", &json!({"tab": "tab_1", "selector": "h1"})).await;
    assert_eq!(answer, json!({"error": cmux_phone_page::NOT_ON_PHONE, "message": "mirrored"}));
    let answer = phones.call(None, "browser.page.cookies.get", &json!({"tab": "tab_1"})).await;
    assert_eq!(answer["error"], cmux_phone_page::UNSUPPORTED);
}

#[tokio::test]
async fn a_silent_phone_times_out_and_a_closed_one_fails_gone() {
    let phones = leak();
    let key = fake_phone(phones, "dev-1", "", |_| None);
    let wait = Duration::from_millis(50);
    let answer = phones.call_within(None, "browser.page.state", &json!({"tab": "tab_1"}), wait).await;
    assert_eq!(answer["error"], cmux_phone_page::TIMEOUT);

    let params = json!({"tab": "tab_1"});
    let call = tokio::spawn(async move {
        phones.call_within(None, "browser.page.state", &params, Duration::from_secs(5)).await
    });
    tokio::time::sleep(Duration::from_millis(10)).await;
    phones.detach(key);
    // The channel's waiting calls fail at once, not at their timeout.
    let answer = call.await.expect("the call ends");
    assert_eq!(answer["error"], cmux_phone_page::GONE);
    assert!(phones.linked().is_empty());
}

#[tokio::test]
async fn several_phones_need_a_device() {
    let phones = leak();
    fake_phone(phones, "dev-1", "iPhone", |r| Some(cmux_phone_page::answer_line(r.id, Ok(json!({"n": 1})))));
    fake_phone(phones, "dev-2", "iPad", |r| Some(cmux_phone_page::answer_line(r.id, Ok(json!({"n": 2})))));
    let answer = phones.call(None, "browser.page.state", &json!({"tab": "tab_1"})).await;
    assert_eq!(answer["error"], cmux_phone_page::AMBIGUOUS);
    let answer = phones.call(Some("dev-2"), "browser.page.state", &json!({"tab": "tab_1"})).await;
    assert_eq!(answer["value"]["n"], 2);
}

#[test]
fn lines_split_across_frames_and_refuse_a_runaway() {
    let mut lines = Lines::default();
    assert_eq!(lines.push(b"{\"a\"", 64).unwrap(), Vec::<Vec<u8>>::new());
    assert_eq!(
        lines.push(b":1}\n{\"b\":2}\n", 64).unwrap(),
        vec![b"{\"a\":1}".to_vec(), b"{\"b\":2}".to_vec()]
    );
    assert!(lines.push(&[b'x'; 65], 64).is_err());
}
