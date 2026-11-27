use super::web_url_for_session;

#[test]
fn a_session_link_puts_the_session_in_the_query_and_keeps_the_fragment() {
    let url = web_url_for_session("http://127.0.0.1:1/#token=t", "s1");
    assert_eq!(url, "http://127.0.0.1:1/?session=s1#token=t");
    assert_eq!(web_url_for_session("http://h/", "s1"), "http://h/?session=s1");
    assert_eq!(
        web_url_for_session("http://h/?a=1#token=t", "s"),
        "http://h/?a=1&session=s#token=t"
    );
}
