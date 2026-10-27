//! Images of a turn (chief-done.md item 12: "a Chief sees the images of its
//! turn, and its OptChat log keeps a reference and a description").
//!
//! A human message's `attachment` parts with an image type are read from the
//! conversation owner (`conversation-attachment-read`) and go to the turn's
//! agent as ACP `image` blocks next to the message text. The OptChat log
//! keeps the user line's text plus one reference per image (its SHA-256,
//! name, size and type), never the bytes; a description of each image,
//! written by the compactor's deny-all model, follows as a `note` line that
//! names the same hash, so the compactor summarizes the image from words.

use cmux_conversation::{Message, Part};
use serde_json::{Value, json};

use crate::daemon::ConversationPort;

/// Image types every vision model the Chief runs on reads.
const VIEWABLE: [&str; 4] = ["image/jpeg", "image/png", "image/gif", "image/webp"];
/// Largest image sent as is: the Messages API takes at most 5 MB of
/// base64 per image (3.75 MB of bytes). A larger one goes as a smaller
/// copy (`image_fit`).
pub const MAX_ORIGINAL_BYTES: u64 = 3_750_000;
/// Longest side the Messages API takes; a larger image goes as a copy.
pub const MAX_ORIGINAL_SIDE: u32 = 8000;

/// One image of a turn, its bytes already base64 (as the owner sends them).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnImage {
    /// Where the bytes are: re-read after a restart to finish a description.
    pub source: ImageRef,
    pub hash: String,
    pub name: String,
    /// The type of the bytes in `data` (a preview is JPEG or WebP).
    pub mime_type: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// None when the image could not be read; the log still names it.
    pub data: Option<String>,
    /// How the model got it when not as the original ("sent as 2000x1139
    /// JPEG"), or why it did not ("not readable: ..."). Logged in the
    /// reference, so the Chief (and zoom) knows what it saw.
    pub note: Option<String>,
}

impl TurnImage {
    /// The log's reference: `[image sha256:<12 hex> "name" WxH type]`.
    pub fn reference(&self) -> String {
        let size = match (self.width, self.height) {
            (Some(w), Some(h)) => format!(" {w}x{h}"),
            _ => String::new(),
        };
        let note = match (&self.note, &self.data) {
            (Some(note), _) => format!(", {note}"),
            (None, None) => ", not readable".to_owned(),
            (None, Some(_)) => String::new(),
        };
        format!(
            "[image sha256:{} \"{}\"{size} {}{note}]",
            short(&self.hash),
            self.name,
            self.original_mime_type()
        )
    }

    /// The type of the original (the part's), not of the bytes sent.
    fn original_mime_type(&self) -> &str {
        match &self.source.part {
            Part::Attachment { mime_type, .. } => mime_type,
            _ => &self.mime_type,
        }
    }

    /// The ACP prompt block (acpmux turns it into an Anthropic image).
    pub fn block(&self) -> Option<Value> {
        let data = self.data.as_ref()?;
        Some(json!({"type": "image", "mimeType": self.mime_type, "data": data}))
    }
}

/// The first 12 hex characters of a hash.
pub fn short(hash: &str) -> &str {
    &hash[..hash.len().min(12)]
}

/// The image parts of `message`, read from the owner (see [`read_image`]).
pub fn read_images(port: &mut dyn ConversationPort, message: &Message) -> Vec<TurnImage> {
    message
        .parts
        .iter()
        .filter_map(|part| {
            read_image(
                port,
                &ImageRef {
                    conversation: message.conversation.clone(),
                    part: part.clone(),
                },
            )
        })
        .collect()
}

/// One image part read from the owner (None when it is not an image part),
/// best first: the original when the model takes its type, bytes and size;
/// else a copy made here from the original (at most 2000 px, a JPEG under
/// the byte limit); else the client's preview (1024 px); else a reference
/// without bytes whose note says why. Never silently dropped.
pub fn read_image(port: &mut dyn ConversationPort, source: &ImageRef) -> Option<TurnImage> {
    let Part::Attachment {
        hash,
        name,
        mime_type,
        byte_count,
        width,
        height,
        preview,
        ..
    } = &source.part
    else {
        return None;
    };
    if !mime_type.starts_with("image/") {
        return None;
    }
    let mut image = TurnImage {
        source: source.clone(),
        hash: hash.clone(),
        name: name.clone(),
        mime_type: mime_type.clone(),
        width: *width,
        height: *height,
        data: None,
        note: None,
    };
    let mut why: Vec<String> = Vec::new();
    let viewable = VIEWABLE.contains(&mime_type.as_str());
    let side_ok = width.unwrap_or(0).max(height.unwrap_or(0)) <= MAX_ORIGINAL_SIDE;
    if viewable && *byte_count <= MAX_ORIGINAL_BYTES && side_ok {
        match port.attachment(&source.conversation, hash, "original", *byte_count) {
            Ok(data) => {
                image.data = Some(data);
                return Some(image);
            }
            Err(e) => why.push(format!("original: {e}")),
        }
    } else if viewable && *byte_count <= super::image_fit::MAX_SOURCE_BYTES {
        match fitted_copy(port, &source.conversation, hash, *byte_count) {
            Ok((data, w, h)) => {
                image.data = Some(data);
                image.mime_type = "image/jpeg".into();
                image.note = Some(format!("sent as {w}x{h} JPEG"));
                return Some(image);
            }
            Err(e) => why.push(format!("copy: {e}")),
        }
    } else if viewable {
        why.push(format!(
            "original is {byte_count} bytes, over {}",
            super::image_fit::MAX_SOURCE_BYTES
        ));
    } else {
        why.push(format!("the model does not read {mime_type}"));
    }
    match preview {
        Some(preview) => {
            match port.attachment(&source.conversation, hash, "preview", preview.byte_count) {
                Ok(data) => {
                    image.data = Some(data);
                    image.mime_type = preview.mime_type.clone();
                    image.note = Some(format!("sent as its {} preview", preview.mime_type));
                    return Some(image);
                }
                Err(e) => why.push(format!("preview: {e}")),
            }
        }
        None => why.push("no preview".into()),
    }
    image.note = Some(format!("not readable: {}", why.join("; ")));
    Some(image)
}

/// The original read whole and made small enough for the model: its
/// base64, width and height.
fn fitted_copy(
    port: &mut dyn ConversationPort,
    conversation: &str,
    hash: &str,
    byte_count: u64,
) -> Result<(String, u32, u32), String> {
    use base64::Engine as _;
    let b64 = base64::engine::general_purpose::STANDARD;
    let data = port
        .attachment(conversation, hash, "original", byte_count)
        .map_err(|e| format!("reading the original failed: {e}"))?;
    let bytes = b64
        .decode(data.as_bytes())
        .map_err(|e| format!("bad base64: {e}"))?;
    drop(data);
    let fitted = super::image_fit::fit(&bytes, MAX_ORIGINAL_BYTES)?;
    Ok((b64.encode(&fitted.jpeg), fitted.width, fitted.height))
}

/// An image part and its conversation: what the host keeps (pending turn,
/// descriptions not written yet) to read the bytes again after a restart.
/// Never the bytes themselves.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ImageRef {
    pub conversation: String,
    /// An `attachment` part with an image type.
    pub part: Part,
}

impl ImageRef {
    fn key(&self) -> String {
        match &self.part {
            Part::Attachment { hash, .. } => format!("{}/{hash}", self.conversation),
            _ => self.conversation.clone(),
        }
    }
}

/// The user line of a message with images: its text, then one reference
/// per image on its own line.
pub fn logged_text(text: &str, images: &[TurnImage]) -> String {
    let references: Vec<String> = images.iter().map(TurnImage::reference).collect();
    match (text.trim().is_empty(), references.is_empty()) {
        (_, true) => text.to_owned(),
        (true, false) => references.join("\n"),
        (false, false) => format!("{text}\n{}", references.join("\n")),
    }
}

/// The note line that describes an image, naming the same hash as its reference.
pub fn description_line(image: &TurnImage, description: Result<&str, &str>) -> String {
    match description {
        Ok(text) => format!(
            "image sha256:{} \"{}\" shows: {}",
            short(&image.hash),
            image.name,
            text.trim()
        ),
        Err(error) => format!(
            "image sha256:{} \"{}\": no description ({error})",
            short(&image.hash),
            image.name
        ),
    }
}

/// The prompt of a description call: the image, then the instruction.
pub fn describe_blocks(image: &TurnImage) -> Option<Vec<Value>> {
    Some(vec![
        image.block()?,
        json!({"type": "text", "text": DESCRIBE_PROMPT}),
    ])
}

/// What the description model is asked: words the compactor can summarize
/// later, without the image.
pub const DESCRIBE_PROMPT: &str = "Describe this image for a memory log that will be read without the image. \
In at most four sentences say what it is (screenshot, photo, diagram, ...), what it shows, and transcribe its \
important visible text (headings, numbers, short messages) exactly. No preamble.";

/// Writes a description of one image (the compactor's deny-all model).
pub trait Describe: Send + Sync {
    fn describe(&self, blocks: Vec<Value>) -> Result<String, String>;
}

impl super::Brain {
    /// Logs a turn image's description as a note that names its hash, and
    /// forgets the image's pending description.
    pub(super) fn described(&mut self, image: &TurnImage, description: Result<String, String>) {
        let key = image.source.key();
        self.describing.remove(&key);
        let line = description_line(image, description.as_deref().map_err(String::as_str));
        if let Err(e) = self.chat.append(optchat_core::Kind::Note, &line) {
            (self.log)(&format!("logging an image description failed: {e}"));
            return;
        }
        self.state.undescribed.retain(|r| r.key() != key);
        self.save();
    }

    /// Starts one description per readable image, off the brain thread;
    /// each answer comes back as `Input::Described`. The images are saved
    /// as pending first (`HostState::undescribed`), so a host that stops
    /// before an answer describes them after its restart.
    pub(super) fn describe_images(&mut self, images: &[TurnImage]) {
        if self.describer.is_none() {
            return;
        }
        for image in images.iter().filter(|i| i.data.is_some()) {
            if !self
                .state
                .undescribed
                .iter()
                .any(|r| r.key() == image.source.key())
            {
                self.state.undescribed.push(image.source.clone());
            }
        }
        self.save();
        for image in images {
            self.spawn_describe(image);
        }
    }

    /// After a (re)connect: describes the images a stopped host left
    /// pending, reading their bytes from the owner again.
    pub(super) fn describe_pending(&mut self) {
        if self.describer.is_none() {
            return;
        }
        let pending: Vec<ImageRef> = self
            .state
            .undescribed
            .iter()
            .filter(|r| !self.describing.contains(&r.key()))
            .cloned()
            .collect();
        for source in pending {
            let image = match self.daemon.as_mut() {
                Some(daemon) => read_image(daemon.as_mut(), &source),
                None => return,
            };
            match image {
                Some(image) if image.data.is_some() => self.spawn_describe(&image),
                Some(image) => {
                    self.described(&image, Err("the image is no longer readable".into()))
                }
                None => {
                    self.state.undescribed.retain(|r| r.key() != source.key());
                    self.save();
                }
            }
        }
    }

    fn spawn_describe(&mut self, image: &TurnImage) {
        let Some(describer) = self.describer.clone() else {
            return;
        };
        let Some(blocks) = describe_blocks(image) else {
            return;
        };
        if !self.describing.insert(image.source.key()) {
            return;
        }
        let tx = self.tx.clone();
        // The note needs the reference only, never the bytes.
        let image = TurnImage {
            data: None,
            ..image.clone()
        };
        let spawned =
            crate::supervisor::background(&self.supervisor, "optchat-describe", move || {
                let description = describer.describe(blocks);
                let _ = tx.send(super::Input::Described {
                    image: Box::new(image),
                    description,
                });
            });
        if let Err(e) = spawned {
            (self.log)(&format!("starting an image description failed: {e}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;
    use cmux_conversation::{Change, DerivedImage, Op, Summary};
    use std::collections::BTreeMap;

    use crate::daemon::OpError;

    /// An owner holding attachment variants by (hash, variant).
    #[derive(Default)]
    struct Owner {
        files: BTreeMap<(String, String), Vec<u8>>,
        reads: Vec<(String, String)>,
    }

    impl ConversationPort for Owner {
        fn snapshot(&mut self, _: &str, _: u32) -> Result<(Summary, Vec<Message>), OpError> {
            unreachable!()
        }
        fn history(&mut self, _: &str, _: u64, _: u32) -> Result<Vec<Message>, OpError> {
            unreachable!()
        }
        fn op(&mut self, _: &str, _: &str, _: &Op) -> Result<Option<Change>, OpError> {
            unreachable!()
        }
        fn typing(&mut self, _: &str, _: bool) -> Result<(), OpError> {
            unreachable!()
        }
        fn draft(&mut self, _: &str, _: &crate::draft::Draft) -> Result<(), OpError> {
            unreachable!()
        }
        fn attachment(
            &mut self,
            _: &str,
            hash: &str,
            variant: &str,
            _: u64,
        ) -> Result<String, OpError> {
            self.reads.push((hash.into(), variant.into()));
            self.files
                .get(&(hash.to_owned(), variant.to_owned()))
                .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
                .ok_or_else(|| OpError::Rejected("unknown_attachment".into()))
        }
    }

    fn part(mime: &str, bytes: u64, size: (u32, u32), preview: Option<DerivedImage>) -> ImageRef {
        ImageRef {
            conversation: "c1".into(),
            part: Part::Attachment {
                hash: "ab".repeat(32),
                name: "Screenshot 2026-10-19 at 1.16.06 AM.png".into(),
                mime_type: mime.into(),
                byte_count: bytes,
                width: Some(size.0),
                height: Some(size.1),
                duration_ms: None,
                poster: None,
                preview,
            },
        }
    }

    fn decoded(image: &TurnImage) -> image::DynamicImage {
        let b = base64::engine::general_purpose::STANDARD
            .decode(image.data.as_ref().unwrap())
            .unwrap();
        image::load_from_memory(&b).unwrap()
    }

    /// The bug: a 5344x3044 Retina window screenshot (transparent shadow, so
    /// the app made no preview) was over 3.75 MB and reached the Chief as
    /// `not readable`.
    #[test]
    fn a_6k_screenshot_without_preview_reaches_the_model_as_a_copy() {
        let png = super::super::image_fit::tests::screenshot_png(5344, 3044);
        assert!(png.len() as u64 > MAX_ORIGINAL_BYTES);
        let source = part("image/png", png.len() as u64, (5344, 3044), None);
        let mut owner = Owner::default();
        owner
            .files
            .insert(("ab".repeat(32), "original".into()), png);
        let image = read_image(&mut owner, &source).unwrap();
        assert!(image.data.is_some(), "{:?}", image.note);
        assert_eq!(image.mime_type, "image/jpeg");
        let shown = decoded(&image);
        assert_eq!(shown.width(), 2000);
        assert!(image.block().is_some());
        let reference = image.reference();
        assert!(
            reference.contains("5344x3044 image/png, sent as 2000x"),
            "{reference}"
        );
        assert!(!reference.contains("not readable"), "{reference}");
        // The base64 the model gets is under the API's 5 MB.
        assert!(image.data.as_ref().unwrap().len() <= 5_000_000);
    }

    #[test]
    fn a_small_image_goes_as_the_original() {
        let png = super::super::image_fit::tests::screenshot_png(300, 200);
        let source = part("image/png", png.len() as u64, (300, 200), None);
        let mut owner = Owner::default();
        owner
            .files
            .insert(("ab".repeat(32), "original".into()), png.clone());
        let image = read_image(&mut owner, &source).unwrap();
        assert_eq!(image.mime_type, "image/png");
        assert_eq!(image.note, None);
        assert_eq!(decoded(&image).width(), 300);
        assert!(!image.reference().contains(", "), "{}", image.reference());
    }

    #[test]
    fn an_undecodable_large_image_falls_back_to_its_preview() {
        let preview = super::super::image_fit::fit(
            &super::super::image_fit::tests::screenshot_png(1024, 600),
            512_000,
        )
        .unwrap();
        let source = part(
            "image/heic",
            9_000_000,
            (4032, 3024),
            Some(DerivedImage {
                hash: "cd".repeat(32),
                mime_type: "image/jpeg".into(),
                byte_count: preview.jpeg.len() as u64,
            }),
        );
        let mut owner = Owner::default();
        owner
            .files
            .insert(("ab".repeat(32), "preview".into()), preview.jpeg);
        let image = read_image(&mut owner, &source).unwrap();
        assert_eq!(image.mime_type, "image/jpeg");
        assert!(
            image
                .reference()
                .contains("image/heic, sent as its image/jpeg preview")
        );
    }

    #[test]
    fn an_unreadable_image_says_why_in_its_reference() {
        let source = part("image/png", 9_000_000, (5344, 3044), None);
        let mut owner = Owner::default();
        let image = read_image(&mut owner, &source).unwrap();
        assert!(image.data.is_none());
        let reference = image.reference();
        assert!(
            reference.contains("not readable: copy: reading the original failed"),
            "{reference}"
        );
        assert!(reference.contains("no preview"), "{reference}");
    }
}
