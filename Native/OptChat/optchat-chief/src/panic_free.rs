//! Small panic-free helpers, the same as cmux-tui-core's `panic_free`
//! (plans/cmux-next/rust-panic-free.md).
//!
//! [`RecoverPoison`]: a `std::sync` lock is poisoned when a thread panicked
//! while it held the lock. Unwrapping that error turns one panic into a panic
//! in every later user of the lock. The data is what the panicking thread
//! left; the Chief keeps serving with it.

use std::sync::{LockResult, PoisonError};

use serde_json::{Map, Value};

/// `.recover_poison()` in place of `.unwrap()` on any `LockResult`: Mutex,
/// RwLock and Condvar wait results.
pub(crate) trait RecoverPoison<T> {
    fn recover_poison(self) -> T;
}

impl<T> RecoverPoison<T> for LockResult<T> {
    fn recover_poison(self) -> T {
        self.unwrap_or_else(PoisonError::into_inner)
    }
}

/// Panic-free stand-ins for serde_json's `value[key]` read and write.
pub(crate) trait JsonFields {
    /// `value[key]` without the index operator: Null when the key is absent
    /// or the value is not an object.
    fn field(&self, key: &str) -> &Value;
    /// `value[index]` without the index operator: Null when the index is out
    /// of range or the value is not an array.
    fn item(&self, index: usize) -> &Value;
    /// `value[key] = field` without the panic: Null becomes an object (as
    /// `IndexMut` does); any other non-object value is left unchanged.
    fn insert(&mut self, key: &str, field: Value);
    /// `&mut value[key]` without the panic: Null becomes an object and a
    /// missing key is added as Null (as `IndexMut` does); None when the value
    /// is neither an object nor Null.
    fn field_mut(&mut self, key: &str) -> Option<&mut Value>;
    /// `value[path[0]][path[1]]… = field` without the panic: `field_mut` at
    /// each step, so a step that is neither an object nor Null leaves the
    /// value unchanged.
    fn insert_path(&mut self, path: &[&str], field: Value);
}

/// The longest start of `text` at most `max_bytes` long that ends on a
/// character boundary.
pub(crate) fn head_within(text: &str, max_bytes: usize) -> &str {
    let mut chars = text.chars();
    while chars.as_str().len() > max_bytes {
        chars.next_back();
    }
    chars.as_str()
}

/// The longest end of `text` at most `max_bytes` long that starts on a
/// character boundary.
pub(crate) fn tail_within(text: &str, max_bytes: usize) -> &str {
    let mut chars = text.chars();
    while chars.as_str().len() > max_bytes {
        chars.next();
    }
    chars.as_str()
}

static JSON_NULL: Value = Value::Null;

impl JsonFields for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&JSON_NULL)
    }

    fn item(&self, index: usize) -> &Value {
        self.get(index).unwrap_or(&JSON_NULL)
    }

    fn insert(&mut self, key: &str, field: Value) {
        if let Some(slot) = self.field_mut(key) {
            *slot = field;
        }
    }

    fn field_mut(&mut self, key: &str) -> Option<&mut Value> {
        if self.is_null() {
            *self = Value::Object(Map::new());
        }
        Some(self.as_object_mut()?.entry(key).or_insert(Value::Null))
    }

    fn insert_path(&mut self, path: &[&str], field: Value) {
        let mut at = Some(self);
        for key in path {
            at = at.and_then(|value| value.field_mut(key));
        }
        if let Some(slot) = at {
            *slot = field;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_never_panic_on_the_wrong_shape() {
        let v = json!({"a": {"b": [1, 2]}, "s": "text"});
        assert_eq!(v.field("a").field("b").item(1), &json!(2));
        assert!(v.field("missing").field("b").is_null());
        assert!(v.field("s").field("b").is_null());
        assert!(v.field("a").field("b").item(9).is_null());
        assert!(json!([1]).field("a").is_null());
    }

    #[test]
    fn head_and_tail_cut_on_character_boundaries() {
        assert_eq!(head_within("héllo", 2), "h");
        assert_eq!(head_within("héllo", 3), "hé");
        assert_eq!(head_within("ab", 5), "ab");
        assert_eq!(tail_within("hé", 1), "");
        assert_eq!(tail_within("hé", 2), "é");
        assert_eq!(tail_within("ab", 0), "");
    }

    #[test]
    fn writes_fill_null_like_index_mut_and_leave_other_shapes() {
        let mut v = Value::Null;
        v.insert("a", json!(1));
        v.insert_path(&["b", "c"], json!(2));
        assert_eq!(v, json!({"a": 1, "b": {"c": 2}}));
        let mut text = json!({"b": "kept"});
        text.insert_path(&["b", "c"], json!(2));
        assert_eq!(text, json!({"b": "kept"}));
        let mut list = json!([1]);
        list.insert("a", json!(1));
        assert_eq!(list, json!([1]));
    }
}
