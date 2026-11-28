use super::*;

#[test]
fn hyperlink_batches_keep_adjacent_cells_and_close_each_run() -> io::Result<()> {
    let links = Rc::new(RefCell::new(LinkState::default()));
    let mut cell = Cell::default();
    cell.set_symbol("x");
    for x in [0, 1, 3] {
        links.borrow_mut().current.insert((0, x), ("https://example.com".into(), cell.clone()));
    }
    let mut backend = AtomicBackend::new(Vec::new(), links);
    backend.draw((0..4).map(|x| (x, 0, &cell)))?;
    backend.flush()?;
    let encoded = String::from_utf8_lossy(&backend.out);
    assert_eq!(encoded.matches("\x1b]8;;https://example.com\x1b\\").count(), 2);
    assert_eq!(encoded.matches("\x1b]8;;\x1b\\").count(), 2);
    assert_eq!(encoded.matches('x').count(), 6); // four cells and two URL hostnames
    backend.draw(std::iter::empty())?;
    Ok(())
}
